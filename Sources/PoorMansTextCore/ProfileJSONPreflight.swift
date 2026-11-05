import Foundation

enum ProfileJSONPreflight {
    static func validate(_ data: Data) throws {
        do {
            try JSONStructurePreflight.validate(data, limits: .init(depth: 16, nodes: 8_192, keyBytes: 128), documentName: "profile")
        } catch let error as JSONStructurePreflight.Failure {
            throw ConversionProfileError(error.reason)
        }
    }
}
