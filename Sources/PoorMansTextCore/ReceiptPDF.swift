import Foundation
#if os(macOS)
import CoreGraphics
import PDFKit
#endif

public enum ReceiptPDF {
    static let maximumSourceBytes = 64 * 1_024 * 1_024
    static let maximumPages = 1_000
    static let maximumPageCharacters = 100_000
    static let maximumDocumentCharacters = 1_000_000

    public static func read(at url: URL) throws -> ReceiptDocument {
        #if os(macOS)
        return try read(open(at: url))
        #else
        return try LinuxReceiptPDF.read(at: url).document
        #endif
    }

    #if os(macOS)
    public static func open(at url: URL) throws -> PDFDocument {
        let data = try VerifiedFile.open(at: url, failure: { _ in
            ReceiptPDFError("The PDF source could not be read.")
        }) { source in
            guard source.isRegularFile else { throw ReceiptPDFError("The PDF source is not a regular file.") }
            let sizeError = ReceiptPDFError("The PDF source exceeds the 64 MiB limit for this import.")
            guard source.info.st_size <= maximumSourceBytes else { throw sizeError }
            var data = Data()
            _ = try source.readChunks(maximumBytes: maximumSourceBytes, chunkSize: 64 * 1_024,
                                      budgetExceeded: { sizeError }) { chunk in
                data.append(contentsOf: chunk)
                return true
            }
            return data
        }
        guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil,
              let pdf = PDFDocument(data: data) else { throw ReceiptPDFError("The PDF is damaged or unreadable.") }
        try validate(pdf)
        return pdf
    }

    public static func read(_ pdf: PDFDocument) throws -> ReceiptDocument {
        try validate(pdf)
        var pages: [ReceiptPage] = []
        var remainingCharacters = maximumDocumentCharacters
        for index in 0..<pdf.pageCount {
            try ConversionExecution.check()
            try Task.checkCancellation()
            let geometryError = ReceiptPDFError("PDF page \(index + 1) has unusable text coordinates.")
            guard let page = pdf.page(at: index), let dictionary = page.pageRef?.dictionary else { throw geometryError }
            let media = page.bounds(for: .mediaBox)
            let crop = page.bounds(for: .cropBox).intersection(media)
            guard usable(media) else { throw geometryError }
            guard usable(crop) else { throw geometryError }
            var unit: CGFloat = 1
            var declaredUnit: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "UserUnit", &declaredUnit) {
                guard CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit) else { throw geometryError }
            }
            // PDFKit liefert PDF-Benutzereinheiten auch bei gesetztem UserUnit.
            let pointsPerMillimeter = 72 / (25.4 * unit)
            guard pointsPerMillimeter.isFinite, pointsPerMillimeter > 0,
                  scaled(crop, by: pointsPerMillimeter) != nil else { throw geometryError }

            let characterCount = page.numberOfCharacters
            guard (0...min(maximumPageCharacters, remainingCharacters)).contains(characterCount) else {
                throw ReceiptPDFError("The PDF exceeds the text extraction limit for this import.")
            }
            remainingCharacters -= characterCount
            let text = page.string ?? ""
            guard text.utf16.count == characterCount else { throw geometryError }
            let words = try words(in: text, on: page, crop: crop, media: media, pointsPerMillimeter: pointsPerMillimeter,
                                  geometryError: geometryError)
            pages.append(ReceiptPage(pointsPerMillimeter: pointsPerMillimeter, words: words))
        }
        guard pages.contains(where: { !$0.words.isEmpty }) else {
            throw ReceiptPDFError("The PDF contains no usable embedded text. Scanned pages require OCR.")
        }
        return ReceiptDocument(pages: pages)
    }

    private static func validate(_ pdf: PDFDocument) throws {
        guard !pdf.isLocked, !pdf.isEncrypted else { throw ReceiptPDFError("Password-protected PDFs are unsupported.") }
        guard (1...maximumPages).contains(pdf.pageCount) else {
            throw ReceiptPDFError("The PDF must contain between 1 and \(maximumPages) pages.")
        }
    }

    private static func words(in text: String, on page: PDFPage, crop: CGRect, media: CGRect, pointsPerMillimeter: CGFloat,
                              geometryError: ReceiptPDFError) throws -> [ReceiptWord] {
        var words: [ReceiptWord] = []
        var word = String()
        var wordBounds = CGRect.null
        var previousGlyph = CGRect.null
        var line = 0
        var offset = 0

        func finishWord() throws {
            guard !word.isEmpty else { return }
            // PDFKit kann an einer engeren CropBox bereits ganze Zeichen aus
            // dem Quellwort entfernt haben. Direkt am Rand ist es nicht sicher.
            let horizontalMargin = max(12, wordBounds.height * 1.5)
            let verticalMargin = wordBounds.height * 0.75
            guard !(crop.minX > media.minX && wordBounds.minX - crop.minX < horizontalMargin),
                  !(crop.maxX < media.maxX && crop.maxX - wordBounds.maxX < horizontalMargin),
                  !(crop.minY > media.minY && wordBounds.minY - crop.minY < verticalMargin),
                  !(crop.maxY < media.maxY && crop.maxY - wordBounds.maxY < verticalMargin) else {
                throw ReceiptPDFError("The PDF crop boundary is too close to embedded text for reliable extraction.")
            }
            guard let bounds = scaled(wordBounds, by: pointsPerMillimeter) else { throw geometryError }
            words.append(ReceiptWord(text: word, rectangle: ReceiptRectangle(bounds), line: line))
            word = ""
            wordBounds = .null
        }

        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 1_024) {
                try ConversionExecution.check()
                try Task.checkCancellation()
            }
            let value = String(character)
            let length = value.utf16.count
            defer { offset += length }
            if character.isWhitespace {
                try finishWord()
                if character.isNewline {
                    previousGlyph = .null
                    line += 1
                }
                continue
            }
            // Zeichenindizes von characterBounds und NSString laufen bei
            // synthetischen Umbrüchen auseinander. Die Auswahl belegt beides.
            guard let selection = page.selection(for: NSRange(location: offset, length: length)),
                  selection.string == value else { throw geometryError }
            let bounds = selection.bounds(for: page)
            guard usable(bounds) else { throw geometryError }
            guard crop.intersects(bounds) else {
                try finishWord()
                previousGlyph = .null
                line += 1
                continue
            }
            guard crop.contains(bounds) else {
                throw ReceiptPDFError("The PDF crop boundary cuts through embedded text.")
            }
            if !previousGlyph.isNull {
                let gap = max(bounds.minX - previousGlyph.maxX, previousGlyph.minX - bounds.maxX)
                let height = max(bounds.height, previousGlyph.height)
                if gap > max(12, height * 1.5) || abs(bounds.midY - previousGlyph.midY) > height * 0.75 {
                    try finishWord()
                    line += 1
                }
            }
            word.append(character)
            wordBounds = wordBounds.union(bounds)
            previousGlyph = bounds
        }
        try finishWord()
        return words
    }

    private static func usable(_ box: CGRect) -> Bool {
        !box.isEmpty && !box.isInfinite && box.minX.isFinite && box.minY.isFinite && box.maxX.isFinite && box.maxY.isFinite
    }

    private static func scaled(_ box: CGRect, by pointsPerMillimeter: CGFloat) -> CGRect? {
        let result = CGRect(x: box.minX / pointsPerMillimeter, y: box.minY / pointsPerMillimeter,
                            width: box.width / pointsPerMillimeter, height: box.height / pointsPerMillimeter)
        return usable(result) ? result : nil
    }
    #endif
}

struct ReceiptPDFError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}
