import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Begrenzter lokaler Prototyp; noch kein Konvertierungsadapter oder Standard.
enum VisionDocumentRecognizer {
    enum RecognitionError: Error, Equatable {
        case unavailable
        case unsupportedLanguages([String])
        case inputTooLarge
        case resultTooLarge
        case invalidStructure
        case recognitionFailed(String)
    }

    static let maximumPixels = 16_000_000
    static let maximumDimension = 8_192
    static let maximumResultBytes = 2_000_000

    static func supportedLanguages(
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws -> [String] {
        guard systemVersion.majorVersion >= 26 else { throw RecognitionError.unavailable }
        guard #available(macOS 26, *) else { throw RecognitionError.unavailable }
        return RecognizeDocumentsRequest(.revision1).supportedRecognitionLanguages.map(\.maximalIdentifier).sorted()
    }

    static func recognize(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        languages: [String] = [],
        maximumResultBytes: Int = VisionDocumentRecognizer.maximumResultBytes
    ) async throws -> StructuredDocumentRecognition {
        try checkCancellation()
        guard #available(macOS 26, *) else { throw RecognitionError.unavailable }
        try validateInput(width: image.width, height: image.height)
        guard (1...Self.maximumResultBytes).contains(maximumResultBytes) else { throw RecognitionError.resultTooLarge }
        let resolved = try resolveLanguages(languages, supported: supportedLanguages())
        let documents = try await performWithPermit {
            var request = RecognizeDocumentsRequest(.revision1)
            request.textRecognitionOptions.automaticallyDetectLanguage = resolved.isEmpty
            request.textRecognitionOptions.recognitionLanguages = resolved.map { Locale.Language(identifier: $0) }
            request.textRecognitionOptions.useLanguageCorrection = true
            request.textRecognitionOptions.minimumTextHeightFraction = 0.008
            request.textRecognitionOptions.maximumCandidateCount = 1
            request.barcodeDetectionOptions.enabled = false
            let observations = try await request.perform(on: image, orientation: orientation)
            try checkCancellation()
            var mapper = Mapper(remainingBytes: maximumResultBytes)
            guard observations.count <= 16 else { throw RecognitionError.resultTooLarge }
            return try observations.map { try mapper.document($0.document) }
        }
        try checkCancellation()
        return StructuredDocumentRecognition(documents: documents, languages: resolved)
    }

    static func validateInput(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixels / height else { throw RecognitionError.inputTooLarge }
    }

    static func resolveLanguages(_ languages: [String], supported: [String]) throws -> [String] {
        guard languages.count <= 8 else { throw RecognitionError.unsupportedLanguages(languages) }
        var resolved: [String] = []
        for language in languages {
            let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, key.utf8.count <= 64,
                  key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw RecognitionError.unsupportedLanguages([language])
            }
            let canonical = Locale.Language(identifier: key).maximalIdentifier.lowercased()
            guard let match = supported.first(where: { $0.lowercased() == canonical })
                ?? supported.sorted().first(where: { $0.lowercased().hasPrefix(key + "-") }) else {
                throw RecognitionError.unsupportedLanguages([language])
            }
            if !resolved.contains(match) { resolved.append(match) }
        }
        return resolved
    }

    static func performWithPermit<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        try await OCRConcurrencyGate.shared.withAsyncPermit {
            do { return try await operation() }
            catch let error as RecognitionError { throw error }
            catch {
                try checkCancellation()
                if error is CancellationError { throw error }
                throw RecognitionError.recognitionFailed(error.localizedDescription)
            }
        }
    }

    private static func checkCancellation() throws {
        try Task.checkCancellation()
        try ConversionExecution.check()
    }

    @available(macOS 26, *)
    private struct Mapper {
        var remainingBytes: Int
        private var remainingElements = 16_384

        mutating func document(_ container: DocumentObservation.Container) throws -> StructuredDocumentRecognition.Document {
            try checkCancellation()
            return try .init(
                text: text(container.text),
                paragraphs: container.paragraphs.map { try text($0) },
                lists: container.lists.map { list in
                    try consumeElement()
                    return try .init(bounds: list.boundingRegion.boundingBox.cgRect, items: list.items.map {
                        let marker = try consume($0.markerString)
                        return try .init(
                            text: .init(text: consume($0.itemString), bounds: $0.content.boundingRegion.boundingBox.cgRect),
                            marker: marker, markerKind: $0.markerType.flatMap { kind($0) }
                        )
                    })
                },
                tables: container.tables.map { try table($0) }
            )
        }

        private mutating func text(_ value: DocumentObservation.Container.Text) throws -> StructuredDocumentRecognition.Text {
            try .init(text: consume(value.transcript), bounds: value.boundingRegion.boundingBox.cgRect)
        }

        private mutating func table(_ table: DocumentObservation.Container.Table) throws -> StructuredDocumentRecognition.Table {
            try consumeElement()
            var cells: [StructuredDocumentRecognition.Table.Cell] = []
            var seen: [CellAddress: DocumentObservation.Container.Table.Cell] = [:]
            // Verbundene Zellen können in mehreren Zeilen vorkommen. Nur diese
            // identische API-Zelle zusammenführen, nie gleiche Textwerte.
            for row in table.rows {
                try consumeElement()
                for cell in row {
                    try consumeElement()
                    let address = CellAddress(rows: cell.rowRange, columns: cell.columnRange)
                    guard address.rows.lowerBound >= 0, address.rows.upperBound < 1_024,
                          address.columns.lowerBound >= 0, address.columns.upperBound < 1_024 else {
                        throw RecognitionError.invalidStructure
                    }
                    if let previous = seen[address] {
                        guard previous == cell else { throw RecognitionError.invalidStructure }
                        continue
                    }
                    guard cells.count < 4_096 else { throw RecognitionError.resultTooLarge }
                    seen[address] = cell
                    cells.append(try .init(rows: cell.rowRange, columns: cell.columnRange, text: text(cell.content.text)))
                }
            }
            return .init(bounds: table.boundingRegion.boundingBox.cgRect, cells: cells)
        }

        private struct CellAddress: Hashable {
            let rows: ClosedRange<Int>
            let columns: ClosedRange<Int>
        }

        private mutating func consumeElement() throws {
            try checkCancellation()
            guard remainingElements > 0 else { throw RecognitionError.resultTooLarge }
            remainingElements -= 1
        }

        private mutating func consume(_ value: String) throws -> String {
            try consumeElement()
            guard value.utf8.count <= remainingBytes else { throw RecognitionError.resultTooLarge }
            remainingBytes -= value.utf8.count
            return value
        }

        private func kind(_ marker: DocumentObservation.Container.List.Marker) -> StructuredDocumentRecognition.List.MarkerKind? {
            switch marker {
            case .bullet: .bullet
            case .hyphen: .hyphen
            case .lowercaseLatin: .lowercaseLatin
            case .uppercaseLatin: .uppercaseLatin
            case .decimal: .decimal
            case .decorativeDecimal: .decorativeDecimal
            case .compositeDecimal: .compositeDecimal
            @unknown default: nil
            }
        }
    }
}
