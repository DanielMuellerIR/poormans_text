#if os(Linux)
import Foundation

struct ReceiptEditorSourceIdentity: Decodable {
    let sha256: String
    let byteCount: Int
}

public enum ReceiptEditorProtocol {
    private static let wordLimit = 10_000
    private static let maximumResponseBytes = 16 * 1_024 * 1_024

    private enum Action: String, Decodable {
        case inspect, previewPage, evaluate, export, loadMask, saveMask
    }

    private struct Request: Decodable {
        let action: Action
        let source: String?
        let path: String?
        let page: Int?
        let sourceIdentity: ReceiptEditorSourceIdentity?
        let mask: ReceiptMask?
        let corrections: [String: String]?
    }

    private struct Field: Encodable {
        let id: UUID
        let value: String?
        let status: ReceiptValueStatus
        let sources: [ReceiptEvidence]
        let diagnostic: String?

        init(_ value: ReceiptValue) {
            id = value.id
            self.value = value.value
            status = value.status
            sources = value.sources
            diagnostic = value.diagnostic
        }
    }

    private struct Word: Encodable {
        let rectangle: ReceiptRectangle
    }

    private struct Response: Encodable {
        let ok = true
        let version = ProductInfo.version
        let operation = "receipt-editor"
        var mask: ReceiptMask?
        var pages: [LinuxReceiptPageGeometry]?
        var words: [Word]?
        var wordsTruncated: Bool?
        var preview: SourcePreview?
        var sourceIdentity: ConversionSourceIdentity?
        var suggestions: [ReceiptField]?
        var suggestedValues: [Field]?
        var fields: [Field]?
        var result: ReceiptResult?
        var evaluationError: String?

        mutating func setWords(_ words: [ReceiptWord]) {
            self.words = words.prefix(ReceiptEditorProtocol.wordLimit).map { Word(rectangle: $0.rectangle) }
            wordsTruncated = words.count > ReceiptEditorProtocol.wordLimit
        }

        mutating func setResult(_ result: ReceiptResult) {
            if Set(result.fields.map(\.name)).count == result.fields.count {
                self.result = result
            } else {
                fields = result.fields.map(Field.init)
            }
        }
    }

    public static func run(
        requestFile: URL, cancellation: ConversionCancellationToken = ConversionCancellationToken()
    ) throws -> Data {
        let context = ConversionExecution.Context(cancellation: cancellation, progress: nil, processTimeout: nil)
        return try ConversionExecution.$current.withValue(context) {
            try ConversionExecution.check()
            let data = try VerifiedFileStaging.contents(of: requestFile, maximumBytes: 2_000_000,
                                                        describedAs: "the receipt editor request")
            try JSONStructurePreflight.validate(data, limits: .init(depth: 16, nodes: 25_000, keyBytes: 128),
                                                documentName: "receipt editor request")
            let request = try JSONDecoder().decode(Request.self, from: data)
            var payload = try execute(request)
            let encoder = JSONEncoder()
            var response = try encoder.encode(payload)
            if response.count >= maximumResponseBytes, request.action == .inspect,
               payload.result != nil || payload.fields != nil {
                payload.result = nil
                payload.fields = nil
                // Der Editor kann die Auswertung separat vom Raster erneut anfordern.
                response = try encoder.encode(payload)
            }
            guard response.count < maximumResponseBytes else {
                throw ReceiptError.invalidDocument("The receipt preview exceeds its response size limit.")
            }
            response.append(0x0A)
            return response
        }
    }

    private static func execute(_ request: Request) throws -> Response {
        switch request.action {
        case .loadMask:
            return Response(mask: try ReceiptMask.load(from: url(request.path)))
        case .saveMask:
            try mask(request).save(to: url(request.path))
            return Response()
        case .inspect:
            let page = request.page ?? 0
            let loaded = try LinuxReceiptPDF.read(at: url(request.source), renderPage: page,
                                                  expectedIdentity: request.sourceIdentity)
            let index = try ReceiptExtractor.Prepared(loaded.document)
            let suggestions = try index.suggestions()
            let suggestedValues = try? index.evaluate(ReceiptMask(fields: suggestions))
            var response = Response(pages: loaded.pages, preview: loaded.preview, sourceIdentity: loaded.sourceIdentity,
                                    suggestions: suggestions, suggestedValues: suggestedValues?.fields.map(Field.init) ?? [])
            response.setWords(loaded.document.pages[page].words)
            if request.mask != nil {
                do {
                    response.setResult(try evaluate(request, index: index))
                } catch let error as ReceiptError {
                    response.evaluationError = error.localizedDescription
                }
            }
            try ConversionExecution.check()
            return response
        case .previewPage:
            guard let identity = request.sourceIdentity, let page = request.page else {
                throw ReceiptPDFError("The receipt page preview requires a verified PDF identity and page.")
            }
            let loaded = try LinuxReceiptPDF.previewPage(at: url(request.source), page: page, expectedIdentity: identity)
            var response = Response(preview: loaded.preview)
            response.setWords(loaded.words)
            return response
        case .evaluate, .export:
            let loaded = try LinuxReceiptPDF.read(at: url(request.source), expectedIdentity: request.sourceIdentity,
                                                  includeIdentity: true)
            let result = try evaluate(request, index: ReceiptExtractor.Prepared(loaded.document))
            if request.action == .export {
                try ConversionExecution.check()
                try result.write(to: url(request.path))
                return Response()
            }
            var response = Response(sourceIdentity: loaded.sourceIdentity)
            response.setResult(result)
            return response
        }
    }

    private static func evaluate(_ request: Request, index: ReceiptExtractor.Prepared) throws -> ReceiptResult {
        var result = try index.evaluate(mask(request))
        for (key, value) in request.corrections ?? [:] {
            guard let id = UUID(uuidString: key) else {
                throw ReceiptError.invalidMask("A correction references an invalid field identifier.")
            }
            result.correct(field: id, value: value)
        }
        return result
    }

    private static func mask(_ request: Request) throws -> ReceiptMask {
        guard let mask = request.mask, mask.version == 1, mask.fields.count <= ReceiptMask.maximumFields,
              Set(mask.fields.map(\.id)).count == mask.fields.count else {
            throw ReceiptError.invalidMask("The receipt editor requires a version 1 mask with up to 500 distinct fields.")
        }
        return mask
    }

    private static func url(_ path: String?) throws -> URL {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else {
            throw ReceiptPDFError("The receipt editor requires an absolute local path.")
        }
        return URL(fileURLWithPath: path)
    }
}
#endif
