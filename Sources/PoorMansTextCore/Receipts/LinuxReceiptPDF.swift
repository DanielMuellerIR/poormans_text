#if os(Linux)
import Foundation

struct LinuxReceiptPageGeometry: Codable {
    let bounds: ReceiptRectangle
    let rotation: Int
}

struct LinuxReceiptPDF {
    private struct Manifest: Decodable { let characterCounts: [Int] }

    private struct PagePayload: Decodable {
        let geometry: LinuxReceiptPageGeometry
        let pointsPerMillimeter: Double
        let words: [Word]
    }

    private struct Word: Decodable {
        let text: String
        let rectangle: ReceiptRectangle
        let line: Int

        var receiptWord: ReceiptWord { ReceiptWord(text: text, rectangle: rectangle, line: line) }
    }

    let document: ReceiptDocument
    let pages: [LinuxReceiptPageGeometry]
    let sourceIdentity: ConversionSourceIdentity?
    let preview: SourcePreview?

    static func read(
        at url: URL, renderPage: Int? = nil, expectedIdentity: ReceiptEditorSourceIdentity? = nil,
        includeIdentity: Bool = false
    ) throws -> Self {
        try withSnapshot(
            at: url, expectedIdentity: expectedIdentity, includeIdentity: includeIdentity || renderPage != nil
        ) {
            snapshot, identity in
            let payloads = try readPages(snapshot)
            var preview: SourcePreview?
            if let renderPage, let identity {
                guard payloads.indices.contains(renderPage) else {
                    throw ReceiptPDFError("The selected page does not exist in this PDF.")
                }
                preview = try LinuxSourcePreview.renderVerifiedSnapshot(
                    snapshot, original: url, identity: identity,
                    selection: .page(renderPage + 1))
            }
            let pages = payloads.map { page in
                ReceiptPage(
                    pointsPerMillimeter: page.pointsPerMillimeter,
                    words: page.words.map(\.receiptWord))
            }
            guard pages.contains(where: { !$0.words.isEmpty }) else {
                throw ReceiptPDFError("The PDF contains no usable embedded text. Scanned pages require OCR.")
            }
            return Self(
                document: ReceiptDocument(pages: pages), pages: payloads.map(\.geometry),
                sourceIdentity: identity, preview: preview)
        }
    }

    static func previewPage(
        at url: URL, page: Int, expectedIdentity: ReceiptEditorSourceIdentity
    ) throws -> (words: [ReceiptWord], preview: SourcePreview) {
        guard (0..<ReceiptPDF.maximumPages).contains(page) else {
            throw ReceiptPDFError("The selected page does not exist in this PDF.")
        }
        return try withSnapshot(at: url, expectedIdentity: expectedIdentity, includeIdentity: true) {
            snapshot, identity in
            guard let identity, let payload = try readPages(snapshot, page: page).first else {
                throw ReceiptPDFError("The selected page does not exist in this PDF.")
            }
            let preview = try LinuxSourcePreview.renderVerifiedSnapshot(
                snapshot, original: url, identity: identity,
                selection: .page(page + 1))
            return (payload.words.map(\.receiptWord), preview)
        }
    }

    private static func withSnapshot<T>(
        at url: URL, expectedIdentity: ReceiptEditorSourceIdentity?, includeIdentity: Bool,
        use: (URL, ConversionSourceIdentity?) throws -> T
    ) throws -> T {
        try LinuxPathValidation.validate(url)
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { sourceDirectory in
            let snapshot = sourceDirectory.appendingPathComponent("source.pdf")
            do {
                try VerifiedFileStaging.stage(
                    from: url, to: snapshot, maximumBytes: ReceiptPDF.maximumSourceBytes,
                    describedAs: "The PDF source (64 MiB limit)")
            } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
                throw ReceiptPDFError(error.localizedDescription)
            }
            let prefix = try VerifiedFileStaging.prefix(
                of: snapshot, maximumBytes: ReceiptPDF.maximumSourceBytes,
                prefixBytes: 1024, describedAs: "the PDF source")
            guard prefix.range(of: Data("%PDF-".utf8)) != nil else {
                throw ReceiptPDFError("The PDF is damaged or unreadable.")
            }
            var identity: ConversionSourceIdentity?
            if includeIdentity || expectedIdentity != nil {
                let fingerprint = try ConversionFileFingerprint.read(snapshot)
                if let expectedIdentity,
                    expectedIdentity.sha256 != fingerprint.sha256
                        || expectedIdentity.byteCount != fingerprint.byteCount
                {
                    throw ReceiptPDFError("The PDF source has changed. Open it again to continue.")
                }
                identity = ConversionSourceIdentity(
                    name: url.lastPathComponent, sha256: fingerprint.sha256,
                    byteCount: fingerprint.byteCount, unavailableReason: nil)
            }
            return try use(snapshot, identity)
        }
    }

    private static func readPages(_ snapshot: URL, page: Int? = nil) throws -> [PagePayload] {
        try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            var arguments = ["receipt", snapshot.path]
            if let page { arguments.append(String(page)) }
            let result = try LinuxBackendResources.runPython(
                script: "poppler", arguments: arguments,
                in: directory, readOnlyPaths: [snapshot])
            try ConversionExecution.check()
            if result.status == 69 {
                let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty { throw ReceiptPDFError(detail) }
                throw PlatformBackendUnavailable("local receipt PDF")
            }
            if result.status == 74 { throw ConversionError.fileSystemFailure(result.standardError) }
            guard result.status == 0,
                result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ReceiptPDFError(detail.isEmpty ? "The PDF is damaged or unreadable." : detail)
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(result.standardOutput.utf8))
            let counts = manifest.characterCounts
            let invalidProtocol = ReceiptPDFError(
                "The local PDF backend returned unusable receipt text coordinates.")
            guard (1...ReceiptPDF.maximumPages).contains(counts.count), page == nil || counts.count == 1,
                counts.allSatisfy({ (0...ReceiptPDF.maximumPageCharacters).contains($0) }),
                counts.reduce(0, +) <= ReceiptPDF.maximumDocumentCharacters
            else { throw invalidProtocol }
            return try counts.enumerated().map { index, count in
                try ConversionExecution.check()
                let url = directory.appendingPathComponent("receipt-\((page ?? index) + 1).json")
                let data = try VerifiedFileStaging.contents(
                    of: url, maximumBytes: 16 * 1024 * 1024,
                    describedAs: "the locally generated PDF receipt page",
                    followSourceSymlink: false)
                let page = try JSONDecoder().decode(PagePayload.self, from: data)
                guard page.geometry.bounds.isValid, [0, 90, 180, 270].contains(page.geometry.rotation),
                    page.pointsPerMillimeter.isFinite, page.pointsPerMillimeter > 0,
                    page.words.count <= count,
                    page.words.allSatisfy({
                        !$0.text.isEmpty && (0...count).contains($0.line) && $0.rectangle.isValid
                    })
                else { throw invalidProtocol }
                return page
            }
        }
    }
}
#endif
