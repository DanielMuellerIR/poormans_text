import AppIntents
import Foundation
import PoorMansTextCore

public struct ShortcutProfile: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversion profile")
    public static let defaultQuery = ShortcutProfileQuery()
    public let id: String
    public var displayRepresentation: DisplayRepresentation { .init(title: "\(id)") }
    public init(name: String) { id = name }
}
public struct ShortcutProfileQuery: EntityStringQuery {
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [ShortcutProfile] {
        let store = ConversionProfileStore()
        return try await Task.detached {
            try identifiers.compactMap { name in
                do { return ShortcutProfile(name: try store.load(named: name).name) }
                catch let error as ConversionProfileError where error.kind == .missing { return nil }
            }
        }.value
    }
    public func suggestedEntities() async throws -> [ShortcutProfile] {
        try await Task.detached { try ConversionProfileStore().profiles().map { ShortcutProfile(name: $0.name) } }.value
    }
    public func entities(matching string: String) async throws -> [ShortcutProfile] {
        try await suggestedEntities().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }
}
