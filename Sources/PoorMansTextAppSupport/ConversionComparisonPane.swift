import AppKit
import SwiftUI
import PoorMansTextCore

public struct ConversionComparisonPane: View {
    public let preview: MarkdownPreview
    public let result: ConversionResult
    @StateObject private var source = ComparisonSourceModel()
    @State private var selectedDiagnostic: Int?
    @State private var location: ConversionLocation?
    @State private var kind: ConversionDiagnosticKind?
    @State private var locationQuery = ""
    @State private var selectedSection: ConversionLocation?
    @State private var cell = ""
    @State private var zoom: CGFloat = 1
    @State private var navigationRequest = 0

    public init(preview: MarkdownPreview, result: ConversionResult) { self.preview = preview; self.result = result }
    private var visualSource: Bool { result.format == .pdf || result.format == .image }
    private var target: ComparisonTarget? {
        guard source.isVerified, preview.matchesExpectedOutput == true else { return nil }
        return ComparisonNavigation.target(for: location, mappings: result.sourceMappings)
    }
    private var sections: [ComparisonSection] { ComparisonNavigation.sections(result.sourceMappings) }
    private var filtered: [Int] {
        result.diagnostics.indices.filter { ComparisonNavigation.matches(result.diagnostics[$0], kind: kind, locationQuery: locationQuery) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label(source.state.message, systemImage: source.isVerified ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(source.isVerified ? Color.secondary : Color.orange)
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Recheck") { source.load(result) }.disabled(source.state == .loading)
            }
            if preview.matchesExpectedOutput != true {
                Text("The result changed or has no output fingerprint. Position jumps are disabled.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !visualSource { sectionNavigation }
            if visualSource {
                HSplitView {
                    sourcePane.frame(minWidth: 220, idealWidth: 340)
                    resultPane.frame(minWidth: 300)
                }
            } else { resultPane }
            diagnostics
        }
        .onAppear { source.load(result) }
        .onDisappear { source.stop() }
        .onChange(of: source.state) { state in if state == .verified { navigate(location) } }
        .onChange(of: source.count) { _ in navigate(location) }
        .onChange(of: kind) { _ in selectedDiagnostic = nil; location = nil }
        .onChange(of: locationQuery) { _ in selectedDiagnostic = nil; location = nil }
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Result").font(.headline)
                if location != nil || selectedDiagnostic != nil {
                    Text(verbatim: ComparisonNavigation.label(location)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            MarkdownPreviewPane(preview: preview, result: result, target: target?.range, targetRequest: navigationRequest)
            if location != nil || selectedDiagnostic != nil, target == nil {
                Text("No verified result position is known for this location.").font(.caption).foregroundStyle(.secondary)
            } else if target?.exact == false {
                Text("Showing the first known position in this section; no exact text position was recorded.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sectionNavigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source layout preview is available for PDFs and images. Other formats use recorded result references.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Result section", selection: $selectedSection) {
                    Text("Choose a section").tag(Optional<ConversionLocation>.none)
                    ForEach(sections) { section in Text(verbatim: section.label).tag(Optional(section.location)) }
                }.onChange(of: selectedSection) { value in cell = ""; selectedDiagnostic = nil; navigate(value) }
                .disabled(sections.isEmpty || !source.isVerified || preview.matchesExpectedOutput != true)
                if selectedSection?.sheet != nil {
                    TextField("Cell, e.g. A1", text: $cell).frame(width: 120).onSubmit { navigateCell() }
                    Button("Go") { navigateCell() }.disabled(cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if sections.count == 2048 { Text("The section list is limited to 2,048 entries.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source").font(.headline)
            HStack(spacing: 8) {
                Button { turn(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous source page or frame").accessibilityLabel(Text("Previous source page or frame"))
                    .disabled(!source.isVerified || source.number <= 1)
                Text(verbatim: source.count > 0 ? "\(source.number) / \(source.count)" : "—").monospacedDigit()
                Button { turn(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next source page or frame").accessibilityLabel(Text("Next source page or frame"))
                    .disabled(!source.isVerified || source.number >= source.count)
                Spacer(minLength: 4)
                Button { zoom = max(0.5, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out").accessibilityLabel(Text("Zoom out")).disabled(source.image == nil)
                Button("Fit") { zoom = 1 }.disabled(source.image == nil)
                Button { zoom = min(4, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in").accessibilityLabel(Text("Zoom in")).disabled(source.image == nil)
            }.controlSize(.small)
            ZStack {
                if let image = source.image { ComparisonRasterView(image: image, zoom: zoom) }
                else if source.state == .loading || source.imageBusy { ProgressView("Loading source preview…") }
                else {
                    Text(source.isVerified ? "Source preview unavailable. Verified result references remain usable." : "Source preview unavailable until the comparison is verified.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(12)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            Text("Source links are inactive. Preview detail is limited; the original remains unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { diagnosticFilters }
            if result.diagnostics.isEmpty { Text("No conversion diagnostics.").font(.caption).foregroundStyle(.secondary) }
            else if filtered.isEmpty { Text("No diagnostics match these filters.").font(.caption).foregroundStyle(.secondary) }
            else {
                List(selection: $selectedDiagnostic) {
                    ForEach(filtered, id: \.self) { index in
                        let warning = result.diagnostics[index]
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: warning.kind == .information ? "info.circle" : "exclamationmark.triangle")
                                .foregroundStyle(warning.kind == .contentLoss ? Color.red : warning.kind == .approximation ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: ComparisonNavigation.kindLabel(warning.kind) + " · " + ComparisonNavigation.label(warning.location)).font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: warning.message).lineLimit(2)
                            }
                        }.tag(index).padding(.vertical, 2)
                    }
                }.listStyle(.bordered).frame(height: 110)
                    .onChange(of: selectedDiagnostic) { index in
                        guard let index, result.diagnostics.indices.contains(index) else { return }
                        navigate(result.diagnostics[index].location)
                    }
            }
            if let index = selectedDiagnostic, result.diagnostics.indices.contains(index) {
                let warning = result.diagnostics[index]
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: warning.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Go to location") { navigate(warning.location) }
                                .disabled(!source.isVerified || preview.matchesExpectedOutput != true
                                    || ComparisonNavigation.target(for: warning.location, mappings: result.sourceMappings) == nil)
                        }
                        Text(verbatim: warning.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxHeight: 70)
            }
        }
    }

    @ViewBuilder private var diagnosticFilters: some View {
        Text("Diagnostics").font(.headline)
        Text(verbatim: "\(filtered.count) / \(result.diagnostics.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Picker("Meaning", selection: $kind) {
            Text("All meanings").tag(Optional<ConversionDiagnosticKind>.none)
            ForEach([ConversionDiagnosticKind.information, .approximation, .contentLoss], id: \.self) { kind in
                Text(verbatim: ComparisonNavigation.kindLabel(kind)).tag(Optional(kind))
            }
        }.frame(maxWidth: 220)
        TextField("Filter locations", text: $locationQuery).textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 260)
    }

    private func navigate(_ location: ConversionLocation?) {
        self.location = location
        navigationRequest += 1
        guard source.isVerified, let number = result.format == .pdf ? location?.page : result.format == .image ? location?.frame : nil,
              number != source.number else { return }
        source.select(number); zoom = 1
    }
    private func turn(_ delta: Int) {
        let number = source.number + delta
        guard (1...max(1, source.count)).contains(number) else { return }
        selectedDiagnostic = nil
        navigate(result.format == .pdf ? ConversionLocation(page: number) : ConversionLocation(frame: number))
    }
    private func navigateCell() {
        guard let sheet = selectedSection?.sheet else { return }
        selectedDiagnostic = nil
        navigate(ConversionLocation(sheet: sheet, cell: cell.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), sheetIndex: selectedSection?.sheetIndex))
    }
}

struct ComparisonRasterView: NSViewRepresentable {
    let image: NSImage
    let zoom: CGFloat
    func makeNSView(context: Context) -> RasterScrollView { RasterScrollView() }
    func updateNSView(_ view: RasterScrollView, context: Context) { view.set(image, zoom: zoom) }
}

final class RasterScrollView: NSScrollView {
    private let picture = NSImageView()
    private let canvas = RasterCanvas()
    private var zoom: CGFloat = 1
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true; hasVerticalScroller = true; autohidesScrollers = true
        drawsBackground = false; picture.imageScaling = .scaleAxesIndependently
        picture.setAccessibilityLabel(NSLocalizedString("Verified source page or frame", comment: ""))
        canvas.addSubview(picture); documentView = canvas
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(_ image: NSImage, zoom: CGFloat) {
        let changed = picture.image !== image || self.zoom != zoom
        picture.image = image; self.zoom = zoom; sizePicture()
        if changed { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
    }
    override func layout() { super.layout(); sizePicture() }
    private func sizePicture() {
        guard let image = picture.image, image.size.width > 0, image.size.height > 0 else { return }
        let available = contentView.bounds.size
        let scale = max(0.001, min(available.width / image.size.width, available.height / image.size.height)) * zoom
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let canvasSize = NSSize(width: max(available.width, size.width), height: max(available.height, size.height))
        let canvasFrame = NSRect(origin: .zero, size: canvasSize)
        let pictureFrame = NSRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2, width: size.width, height: size.height)
        if canvas.frame != canvasFrame { canvas.frame = canvasFrame }
        if picture.frame != pictureFrame { picture.frame = pictureFrame }
    }
}

private final class RasterCanvas: NSView {
    override var isFlipped: Bool { true }
}
