import CryptoKit
import Foundation
import PoorMansTextCore

struct AppProfileFailure: LocalizedError {
    let key: String
    var errorDescription: String? { NSLocalizedString(key, comment: "") }
}

private func profileRevision(_ profile: ConversionProfile) throws -> String {
    SHA256.hash(data: try profile.encoded()).map { String(format: "%02x", $0) }.joined()
}

extension AppModel {
    public var hasUnsavedProfileChanges: Bool {
        guard let selectedProfile else { return false }
        return selectedProfile.options != ConversionProfileOptions(conversionOptions)
    }
    public var usesExactProfileDestination: Bool {
        guard let destination = selectedProfile?.localTargets?.outputDirectory else { return false }
        return destinationFolder?.standardizedFileURL == destination.standardizedFileURL
    }
    public func refreshProfiles() {
        do {
            profiles = try profileStore.profiles()
            if let name = selectedProfileName {
                let current = try profileStore.load(named: name)
                let revision = try profileRevision(current)
                if (selectedProfile != nil && selectedProfile != current) || (selectedProfileRevision != nil && selectedProfileRevision != revision) {
                    profileNeedsReload = true
                    profileMessage = NSLocalizedString("The saved profile changed. Reload it or use current settings without a profile.", comment: "")
                }
                if selectedProfile == nil { selectedProfile = current }
            }
        } catch { profileMessage = AppErrorMessage.describe(error) }
    }
    public func selectProfile(named name: String?, allowLocalTargets: Bool = false) throws {
        guard acceptsNewDocuments else { throw AppProfileFailure(key: "Wait for the current conversion before changing profiles.") }
        guard let name else {
            selectedProfile = nil; selectedProfileName = nil; profileAllowsLocalTargets = false
            selectedProfileRevision = nil; profileNeedsReload = false
            profileMessage = nil; savePreferences(); return
        }
        let profile = try profileStore.load(named: name)
        try profile.requireLocalPermission(allowLocalTargets)
        let values = profile.options
        imageTextRecognition = values.imageTextRecognition; spreadsheetRendering = values.spreadsheetRendering
        frontmatter = values.frontmatter; outputLayout = values.outputLayout
        pdfTextRecognition = values.pdfTextRecognition; ocrMethod = values.ocrMethod; docxChangeMode = values.docxChangeMode
        pdfLayout = values.pdfLayout; ocrLanguageCodes = values.ocrLanguages.joined(separator: ",")
        pdfRemoveHeadersFooters = values.pdfRemoveHeadersFooters; pdfDehyphenate = values.pdfDehyphenate
        presentationIncludeNotes = values.presentationIncludeNotes; sourceMapping = values.sourceMapping
        conversionReport = values.conversionReport
        profilePandocExecutable = profile.localTargets?.pandocExecutable
        if let destination = profile.localTargets?.outputDirectory { destinationFolder = destination }
        selectedProfile = profile; selectedProfileName = profile.name; profileAllowsLocalTargets = allowLocalTargets
        selectedProfileRevision = try profileRevision(profile); profileNeedsReload = false
        profileMessage = nil; savePreferences()
    }
    public func saveProfile(named name: String, duplicateSelected: Bool = false) throws {
        guard acceptsNewDocuments else { throw AppProfileFailure(key: "Wait for the current conversion before changing profiles.") }
        if duplicateSelected && profileNeedsReload { throw AppProfileFailure(key: "The saved profile changed. Reload it or use current settings without a profile.") }
        var options = conversionOptions; options.pandocExecutable = nil
        var profile = try ConversionProfile(name: name, options: options)
        if duplicateSelected, let selectedProfile {
            profile.documentBinding = selectedProfile.documentBinding; profile.localTargets = selectedProfile.localTargets
        }
        try profileStore.save(profile, allowLocalTargets: profileAllowsLocalTargets)
        profiles = try profileStore.profiles(); selectedProfile = profile; selectedProfileName = profile.name
        selectedProfileRevision = try profileRevision(profile); profileNeedsReload = false
        profileMessage = nil; savePreferences()
    }
    public func updateSelectedProfile() throws {
        guard acceptsNewDocuments, let expected = selectedProfile else { throw AppProfileFailure(key: "Choose a saved profile first.") }
        guard !profileNeedsReload else { throw AppProfileFailure(key: "The saved profile changed. Reload it or use current settings without a profile.") }
        var profile = expected; profile.options = ConversionProfileOptions(conversionOptions)
        try profileStore.update(profile, replacing: expected, allowLocalTargets: profileAllowsLocalTargets)
        selectedProfile = profile; profiles = try profileStore.profiles(); profileMessage = nil
        selectedProfileRevision = try profileRevision(profile); savePreferences()
    }
    public func deleteSelectedProfile() throws {
        guard acceptsNewDocuments, let expected = selectedProfile else { throw AppProfileFailure(key: "Choose a saved profile first.") }
        guard !profileNeedsReload else { throw AppProfileFailure(key: "The saved profile changed. Reload it or use current settings without a profile.") }
        try profileStore.delete(expected)
        selectedProfile = nil; selectedProfileName = nil; profileAllowsLocalTargets = false
        selectedProfileRevision = nil; profileNeedsReload = false
        profiles = try profileStore.profiles(); profileMessage = nil; savePreferences()
    }
    public func clearProfileDocumentBinding() throws {
        guard acceptsNewDocuments else { throw AppProfileFailure(key: "Wait for the current conversion before changing profiles.") }
        // Die gespeicherte Bindung bleibt bestehen. Aktuelle Werte werden bewusst
        // als manuelle Einstellungen weiterverwendet, auch für Mehrfachimporte.
        try selectProfile(named: nil)
    }
    public func addExampleProfile(scans: Bool) throws {
        let options = scans
            ? ConversionOptions(pdfTextRecognition: .always, ocrMethod: .structured, sourceMapping: true, conversionReport: true)
            : ConversionOptions(outputLayout: .textbundle, docxChangeMode: .mark, sourceMapping: true, conversionReport: true)
        let name = NSLocalizedString(scans ? "Example — Local scans" : "Example — Document review", comment: "")
        try profileStore.save(ConversionProfile(name: name, options: options))
        refreshProfiles()
        profileMessage = NSLocalizedString("Example profile added. Choose it in the profile menu.", comment: "")
    }
    func profileInvocation() -> AppProfileInvocation {
        .init(profile: selectedProfile, requestedName: selectedProfileName, store: profileStore, allowLocalTargets: profileAllowsLocalTargets, exactDestination: usesExactProfileDestination, requiresReload: profileNeedsReload)
    }
}

struct AppProfileInvocation: Sendable {
    let profile: ConversionProfile?
    let requestedName: String?
    let store: ConversionProfileStore
    let allowLocalTargets: Bool
    let exactDestination: Bool
    let requiresReload: Bool
    func verify() throws {
        guard !requiresReload else { throw AppProfileFailure(key: "The saved profile changed. Reload it or use current settings without a profile.") }
        if requestedName != nil, profile == nil { throw AppProfileFailure(key: "The selected profile is missing. Choose another profile or current settings.") }
        guard let profile else { return }
        guard try store.load(named: profile.name) == profile else { throw AppProfileFailure(key: "The saved profile changed. Reload it or use current settings without a profile.") }
        try profile.requireLocalPermission(allowLocalTargets)
    }
    func prepare(_ request: ConversionRequest, cancellation: ConversionCancellationToken) throws -> ConversionRequest {
        try verify()
        guard let profile else { return request }
        var keys: Set<ConversionProfileOptionKey> = [.spreadsheetRendering, .imageTextRecognition, .frontmatter, .outputLayout, .pdfTextRecognition, .ocrLanguages, .ocrMethod, .docxChangeMode, .pdfLayout, .pdfRemoveHeadersFooters, .pdfDehyphenate, .presentationIncludeNotes, .sourceMapping, .conversionReport, .pandocExecutable]
        if request.options.pdfPages != nil { keys.insert(.pdfPages) }
        if request.options.epubChapters != nil { keys.insert(.epubChapters) }
        if request.options.presentationSelection != nil { keys.insert(.presentationSlides) }
        if request.options.spreadsheetSelection != nil { keys.formUnion([.spreadsheetSheets, .spreadsheetRanges]) }
        var overrides = request.options
        if let selection = overrides.presentationSelection { overrides.presentationIncludeNotes = selection.includeNotes }
        let resolved = try profile.resolve(for: request.inputURL, overriding: overrides, explicit: keys, allowLocalTargets: allowLocalTargets, cancellation: cancellation)
        return .init(inputURL: request.inputURL, destination: request.destination, options: resolved.options, expectedSourceIdentity: request.expectedSourceIdentity ?? resolved.expectedSourceIdentity)
    }
    func validateBatch() throws {
        try verify()
        guard profile?.documentBinding == nil else { throw AppProfileFailure(key: "This profile is bound to one document. Use current settings without its binding for batch conversion.") }
        guard !exactDestination else { throw AppProfileFailure(key: "The local profile specifies one exact output folder. Choose a batch destination or current settings.") }
    }
    func validateClipboard() throws {
        try verify()
        guard profile?.documentBinding == nil else { throw AppProfileFailure(key: "A document-bound profile cannot be used for clipboard text. Choose current settings first.") }
    }
}
