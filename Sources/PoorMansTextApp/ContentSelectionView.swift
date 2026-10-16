import PoorMansTextCore
import PoorMansTextAppSupport
import SwiftUI

struct ContentSelectionTicket: Identifiable {
    let id = UUID()
    let input: URL
}

struct ContentSelectionView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ContentSelectionModel
    @State private var positions = ""
    @State private var cells = ""
    @State private var includeNotes = true
    @FocusState private var positionsFocused: Bool

    init(input: URL) { _model = StateObject(wrappedValue: ContentSelectionModel(input: input)) }

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let detail: String
        var enabled = true
    }
    private var rows: [Row] {
        switch model.overview {
        case .pdf(let value): value.pages.map { .init(id: $0.number, title: String(format: NSLocalizedString("Page %d", comment: ""), $0.number), detail: $0.label ?? "") }
        case .spreadsheet(let value): value.sheets.map { .init(id: $0.index, title: "\($0.index) · \($0.name)", detail: NSLocalizedString($0.visibility.rawValue, comment: "") + ($0.isReadable ? "" : " · " + NSLocalizedString("Unavailable sheet type", comment: "")), enabled: $0.isReadable) }
        case .presentation(let value): value.slides.map { .init(id: $0.number, title: "\($0.number) · \($0.title ?? NSLocalizedString("Untitled slide", comment: ""))", detail: $0.hasNotes ? NSLocalizedString("Notes container present (may be empty)", comment: "") : "") }
        case .epub(let value): value.chapters.map { chapter in
            let navigation = value.navigation.filter { $0.chapter == chapter.number }.map { $0.title + ($0.fragment.map { " #" + $0 } ?? "") }.joined(separator: " · ")
            return .init(id: chapter.number, title: "\(chapter.number) · \(chapter.title ?? chapter.path)", detail: NSLocalizedString(chapter.isLinear ? "Primary content" : "Supplementary content", comment: "") + " · " + chapter.path + (navigation.isEmpty ? "" : "\n" + navigation), enabled: chapter.isReadable)
        }
        default: []
        }
    }
    private var count: Int {
        switch model.overview {
        case .pdf(let value): value.pageCount
        case .spreadsheet(let value): value.sheets.count
        case .presentation(let value): value.slideCount
        case .epub(let value): value.chapterCount
        default: 0
        }
    }
    private var selection: Result<DocumentContentSelection, Error> {
        Result {
            let indices = try ContentSelectionParsing.requiredIndices(positions, count: count)
            switch model.overview {
            case .pdf: return .pdf(indices)
            case .spreadsheet(let value):
                let chosen = Set(try indices.zeroBasedIndices(itemCount: count).map { $0 + 1 })
                guard value.sheets.filter({ chosen.contains($0.index) }).allSatisfy(\.isReadable) else { throw ContentSelectionFailure("The selection includes an unavailable item.") }
                return .spreadsheet(try SpreadsheetSelection(sheets: .indices(indices), ranges: ContentSelectionParsing.ranges(cells)))
            case .presentation: return .presentation(PresentationSelection(slides: indices, includeNotes: includeNotes))
            case .epub(let value):
                let chosen = Set(try indices.zeroBasedIndices(itemCount: count).map { $0 + 1 })
                guard value.chapters.filter({ chosen.contains($0.number) }).allSatisfy(\.isReadable) else { throw ContentSelectionFailure("The selection includes an unavailable item.") }
                return .epub(indices)
            default: throw ContentSelectionFailure("This format supports complete import only.")
            }
        }
    }
    private var selectedCount: Int {
        (try? ContentSelectionParsing.indices(positions)?.zeroBasedIndices(itemCount: count).count) ?? 0
    }
    private var isSelectable: Bool {
        guard let overview = model.overview else { return false }
        if case .complete = overview { return false }
        return true
    }
    private var canConvert: Bool {
        guard app.acceptsNewDocuments, let identity = model.overview?.identity,
              identity.sha256 != nil, identity.byteCount != nil else { return false }
        if case .success = selection { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Content").font(.headline)
            Text(verbatim: model.input.lastPathComponent).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if model.isLoading {
                ProgressView("Reading content overview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ScrollView { Text(verbatim: error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else if isSelectable {
                selectionControls
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            Toggle(isOn: Binding(get: { contains(row.id) }, set: { toggle(row.id, selected: $0) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: row.title).fontWeight(.medium)
                                    if !row.detail.isEmpty { Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox).padding(8).disabled(!row.enabled)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(1)
                }.frame(minHeight: 120)
                if rows.count < count {
                    Text("Overview limited. Enter source numbers above to select items beyond this list.").font(.caption).foregroundStyle(.secondary)
                }
                if case .epub(let value) = model.overview {
                    Text("Chapters select whole spine files. Navigation fragments are for orientation only.").font(.caption).foregroundStyle(.secondary)
                    if value.navigationTruncated { Text("Navigation overview limited.").font(.caption).foregroundStyle(.secondary) }
                    if !value.diagnostics.isEmpty { Text(verbatim: value.diagnostics.map(\.message).joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                if model.overview?.identity?.sha256 == nil || model.overview?.identity?.byteCount == nil {
                    Text("The source could not be verified. Read the content overview again.").foregroundStyle(.red)
                } else if case .failure(let error) = selection {
                    Text(verbatim: error.localizedDescription).font(.callout).foregroundStyle(.red).accessibilityIdentifier("selectionValidation")
                } else {
                    Text(String(format: NSLocalizedString("%d of %d selected", comment: ""), selectedCount, count)).font(.callout).foregroundStyle(.secondary)
                }
            } else if model.overview != nil {
                Text("This format supports complete import only.").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Read Again") { model.load() }.disabled(model.isLoading)
                Spacer()
                Button("Import Complete Document") { model.cancel(); app.convert(model.input); dismiss() }
                    .disabled(model.overview == nil || !app.acceptsNewDocuments)
            }
            HStack {
                Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if isSelectable {
                    Button("Convert Selection") {
                        guard case .success(let selection) = selection, let identity = model.overview?.identity else { return }
                        app.convertSelection(model.input, selection: selection, identity: identity)
                        model.cancel(); dismiss()
                    }.keyboardShortcut(.defaultAction).disabled(!canConvert)
                }
            }
        }
        .padding(20).frame(minWidth: 560, idealWidth: 680, minHeight: 470, idealHeight: 640)
        .task { model.load() }
        .onReceive(model.$overview) { value in
            guard let value else { return }
            switch value {
            case .spreadsheet(let summary): positions = summary.sheets.filter(\.isReadable).map { String($0.index) }.joined(separator: ",")
            case .pdf(let summary): positions = summary.pageCount > 0 ? "1-\(summary.pageCount)" : ""
            case .presentation(let summary): positions = summary.slideCount > 0 ? "1-\(summary.slideCount)" : ""
            case .epub(let summary): positions = summary.chapterCount > 0 ? "1-\(summary.chapterCount)" : ""
            case .complete: positions = ""
            }
            cells = ""; includeNotes = true
        }
        .onDisappear { model.cancel() }
        .onChange(of: app.isConverting) { active in if active { model.cancel(); dismiss() } }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source numbers").font(.callout).fontWeight(.medium)
            TextField("Source numbers (for example 1,3-5)", text: $positions)
                .textFieldStyle(.roundedBorder).focused($positionsFocused).accessibilityIdentifier("selectionPositions")
            HStack {
                Button("All") {
                    if case .spreadsheet(let value) = model.overview { positions = value.sheets.filter(\.isReadable).map { String($0.index) }.joined(separator: ",") }
                    else { positions = count > 0 ? "1-\(count)" : "" }
                }
                Button("None") { positions = "" }
                if case .spreadsheet(let value) = model.overview {
                    Button("Visible Sheets") { positions = value.sheets.filter { $0.isReadable && $0.visibility == .visible }.map { String($0.index) }.joined(separator: ",") }
                        .disabled(value.sheets.contains { $0.isReadable && $0.visibility == .unknown })
                }
                Spacer()
            }
            if case .spreadsheet = model.overview {
                Text("Cell ranges").font(.callout).fontWeight(.medium)
                TextField("Cell ranges (for example A1:C8,E2; empty means whole sheets)", text: $cells)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("selectionCells")
                Text("Ranges apply to every selected sheet. Merged cells and formulas keep the converter's existing limits.").font(.caption).foregroundStyle(.secondary)
            }
            if case .presentation = model.overview {
                Toggle("Include presentation notes", isOn: $includeNotes)
            }
        }
    }
    private func contains(_ number: Int) -> Bool {
        guard let value = try? ContentSelectionParsing.indices(positions) else { return false }
        return value.ranges.contains { $0.contains(number) }
    }
    private func toggle(_ number: Int, selected: Bool) {
        var values = Set((try? ContentSelectionParsing.indices(positions)?.zeroBasedIndices(itemCount: count).map { $0 + 1 }) ?? [])
        if selected { values.insert(number) } else { values.remove(number) }
        positions = values.sorted().map(String.init).joined(separator: ",")
    }
}
