#if os(Linux)
import Foundation

struct ReceiptEditorSourceIdentity: Decodable {
    let sha256: String
    let byteCount: Int
}

public enum ReceiptEditorProtocol {
    private enum Action: String, Decodable {
        case inspect, evaluate, export, loadMask, saveMask
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
        let name: String
        let value: String?
        let status: ReceiptValueStatus
        let sources: [ReceiptEvidence]
        let diagnostic: String?

        init(_ value: ReceiptValue) {
            id = value.id
            name = value.name
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
        var preview: SourcePreview?
        var sourceIdentity: ConversionSourceIdentity?
        var suggestions: [ReceiptField]?
        var suggestedValues: [Field]?
        var fields: [Field]?
        var result: ReceiptResult?
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
            let payload = try execute(request)
            var response = try JSONEncoder().encode(payload)
            guard response.count < 16 * 1024 * 1024 else {
                throw ReceiptError.invalidDocument("The receipt preview exceeds its response size limit.")
            }
            if request.action == .export {
                guard let result = payload.result else {
                    throw ReceiptError.invalidMask("Field names must be unique before exporting.")
                }
                try result.write(to: url(request.path))
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
            let suggestions = ReceiptExtractor.suggestions(in: loaded.document)
            let suggestedValues = try ReceiptExtractor.evaluateForExport(ReceiptMask(fields: suggestions), in: loaded.document)
            return Response(pages: loaded.pages, words: loaded.document.pages[page].words.prefix(10_000).map {
                Word(rectangle: $0.rectangle)
            }, preview: loaded.preview, sourceIdentity: loaded.sourceIdentity,
                suggestions: suggestions, suggestedValues: suggestedValues.fields.map(Field.init))
        case .evaluate, .export:
            let mask = try mask(request)
            let loaded = try LinuxReceiptPDF.read(at: url(request.source), expectedIdentity: request.sourceIdentity,
                                                  includeIdentity: true)
            var result = try ReceiptExtractor.evaluateForExport(mask, in: loaded.document)
            for (key, value) in request.corrections ?? [:] {
                guard let id = UUID(uuidString: key) else {
                    throw ReceiptError.invalidMask("A correction references an invalid field identifier.")
                }
                result.correct(field: id, value: value)
            }
            let uniqueNames = Set(result.fields.map(\.name)).count == result.fields.count
            return Response(sourceIdentity: loaded.sourceIdentity, fields: result.fields.map(Field.init),
                            result: uniqueNames ? result : nil)
        }
    }

    private static func mask(_ request: Request) throws -> ReceiptMask {
        guard let mask = request.mask, mask.version == 1, mask.fields.count <= 500,
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
