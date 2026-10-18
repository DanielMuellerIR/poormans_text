import PoorMansTextCore
import PoorMansTextAppSupport
import SwiftUI

struct ProfileControls: View {
    @ObservedObject var model: AppModel
    @State private var showsManager = false
    @State private var name = ""
    @State private var error: String?
    @State private var pendingChoice: String?
    @State private var localChoice: String?
    @State private var confirmsDelete = false

    var body: some View {
        dialogs(controls, active: !showsManager)
            .sheet(isPresented: $showsManager) { dialogs(manager, active: showsManager) }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { picker; manageButton }
                VStack(alignment: .leading, spacing: 8) { picker; manageButton }
            }
            if model.hasUnsavedProfileChanges {
                Label("Unsaved profile changes", systemImage: "pencil.circle").font(.caption)
                    .accessibilityIdentifier("profileUnsavedChanges")
            }
            if let message = model.profileMessage { Text(verbatim: message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if model.selectedProfile?.documentBinding != nil {
                Text("Bound to one document; other files and batch imports require current settings without the binding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.usesExactProfileDestination {
                Text("The local profile destination is one exact output folder, not a batch destination.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!model.acceptsNewDocuments)
    }
    private func dialogs<V: View>(_ content: V, active: Bool) -> some View {
        content
        .alert("Profile", isPresented: Binding(get: { active && error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(verbatim: error ?? "") }
        .confirmationDialog("Replace unsaved profile changes?", isPresented: Binding(get: { active && pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } }), titleVisibility: .visible) {
            Button("Load Saved Profile") { let choice = pendingChoice; pendingChoice = nil; choose(choice) }
            Button("Cancel", role: .cancel) { pendingChoice = nil }
        } message: { Text("Your current values are kept until you load the saved profile.") }
        .confirmationDialog("Allow local profile paths?", isPresented: Binding(get: { active && localChoice != nil }, set: { if !$0 { localChoice = nil } }), titleVisibility: .visible) {
            Button("Allow and Load") { let choice = localChoice; localChoice = nil; attempt { try model.selectProfile(named: choice, allowLocalTargets: true) } }
            Button("Cancel", role: .cancel) { localChoice = nil }
        } message: { Text("This profile may change the output location or Pandoc executable. Only allow paths you trust on this Mac.") }
    }
    private var picker: some View {
        Picker("Profile", selection: Binding(get: { model.selectedProfileName ?? "" }, set: { value in
            let choice = value.isEmpty ? nil : value
            if choice != nil && model.hasUnsavedProfileChanges { pendingChoice = choice }
            else { choose(choice) }
        })) {
            Text("Current settings").tag("")
            if let name = model.selectedProfileName, !model.profiles.contains(where: { $0.name == name }) {
                Text(verbatim: name).tag(name)
            }
            ForEach(model.profiles, id: \.name) { profile in Text(verbatim: profile.name).tag(profile.name) }
        }
        .pickerStyle(.menu).accessibilityIdentifier("conversionProfile")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var manageButton: some View {
        Button("Manage Profiles…") { model.refreshProfiles(); showsManager = true }
            .accessibilityIdentifier("manageProfiles")
    }
    private var manager: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Profiles").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picker
                    if model.hasUnsavedProfileChanges { Text("Unsaved profile changes").font(.callout).foregroundStyle(.secondary) }
                    if let profile = model.selectedProfile {
                        Text(verbatim: profile.name).fontWeight(.medium).textSelection(.enabled)
                        Text(profile.documentBinding == nil ? LocalizedStringKey("Reusable options") : LocalizedStringKey("Options bound to one document")).font(.caption).foregroundStyle(.secondary)
                        if let local = profile.localTargets {
                            if let destination = local.outputDirectory { Text(verbatim: destination.path).font(.caption).textSelection(.enabled) }
                            if let executable = local.pandocExecutable { Text(verbatim: executable.path).font(.caption).textSelection(.enabled) }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { editButtons }
                            VStack(alignment: .leading, spacing: 8) { editButtons }
                        }
                        if profile.documentBinding != nil {
                            Button("Use Current Settings Without Binding") { attempt { try model.clearProfileDocumentBinding() } }
                                .accessibilityIdentifier("clearProfileBinding")
                        }
                    }
                    Divider()
                    TextField("New profile name", text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("newProfileName")
                    ViewThatFits(in: .horizontal) {
                        HStack { createButtons }
                        VStack(alignment: .leading, spacing: 8) { createButtons }
                    }
                    Text("New profiles save reusable options. Destination and batch parallelism remain separate. Duplicates and updates retain existing document bindings and local paths.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Menu("Add Example Profile") {
                        Button("Local scans") { attempt { try model.addExampleProfile(scans: true) } }
                        Button("Document review") { attempt { try model.addExampleProfile(scans: false) } }
                    }
                    Text("Structured OCR requires macOS 26. Earlier systems use standard OCR and report the fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh Profiles") { model.refreshProfiles() }.accessibilityIdentifier("refreshProfiles")
                    if let message = model.profileMessage { Text(verbatim: message).font(.callout).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { showsManager = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 520)
        .confirmationDialog("Delete Saved Profile?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) { attempt { try model.deleteSelectedProfile() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the saved profile. Current option values are kept.") }
    }
    @ViewBuilder private var editButtons: some View {
        Button("Update Profile") { attempt { try model.updateSelectedProfile() } }
            .disabled(!model.hasUnsavedProfileChanges).accessibilityIdentifier("updateProfile")
        Button("Reload Profile") {
            if model.hasUnsavedProfileChanges { pendingChoice = model.selectedProfileName }
            else { choose(model.selectedProfileName) }
        }.accessibilityIdentifier("reloadProfile")
        Button("Delete…", role: .destructive) { confirmsDelete = true }.accessibilityIdentifier("deleteProfile")
    }
    @ViewBuilder private var createButtons: some View {
        Button("Save New Profile") { attempt { try model.saveProfile(named: name); name = "" } }
            .disabled(name.isEmpty).accessibilityIdentifier("saveNewProfile")
        Button("Duplicate Profile") { attempt { try model.saveProfile(named: name, duplicateSelected: true); name = "" } }
            .disabled(name.isEmpty || model.selectedProfile == nil).accessibilityIdentifier("duplicateProfile")
    }
    private func choose(_ name: String?) {
        if let name, model.profiles.first(where: { $0.name == name })?.localTargets != nil { localChoice = name }
        else { attempt { try model.selectProfile(named: name) } }
    }
    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { self.error = AppErrorMessage.describe(error) }
    }
}
