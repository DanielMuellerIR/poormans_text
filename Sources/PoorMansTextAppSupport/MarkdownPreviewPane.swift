import AppKit
import SwiftUI
import WebKit
import PoorMansTextCore

public struct MarkdownPreviewPane: View {
    public let preview: MarkdownPreview
    public let result: ConversionResult
    public let target: ConversionTextRange?
    public let targetRequest: Int
    @State private var rendered: RenderedMarkdownPreview?
    @State private var assets: PreviewAssets?
    @State private var mode = 0
    @State private var query = ""
    @State private var searchRequest = 0
    @State private var backwards = false
    @State private var matchMissing = false
    @State private var imageFailed = false
    @State private var loading = true
    @State private var selectedFile: LocalFileSelection?
    @FocusState private var searchFocused: Bool

    public init(preview: MarkdownPreview, result: ConversionResult, target: ConversionTextRange? = nil, targetRequest: Int = 0) {
        self.preview = preview; self.result = result; self.target = target; self.targetRequest = targetRequest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewToolbarLayout {
                modePicker
                HStack(spacing: 10) { searchControls }
            }
            if let assets, !assets.localFiles.isEmpty {
                DisclosureGroup("Local files") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(assets.localFiles, id: \.self) { path in
                                Button(path) { selectedFile = LocalFileSelection(path: path) }
                                    .accessibilityIdentifier("previewFile-" + path)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                    if assets.filesTruncated { Text("The file list is limited to 1,024 entries. All files remain in the output folder.").font(.caption) }
                }
            }
            ZStack {
                if mode == 1 {
                    PreviewSourceView(text: preview.text, query: query, request: searchRequest, backwards: backwards,
                                      target: validTarget, targetRequest: targetRequest, missing: { matchMissing = $0 })
                } else if let rendered {
                    PreviewWebView(rendered: rendered, assets: assets, query: query, request: searchRequest,
                                   backwards: backwards, anchor: validTarget.flatMap { rendered.anchor(for: $0)?.id }, anchorRequest: targetRequest,
                                   missing: { matchMissing = $0 }, imageFailed: { imageFailed = true })
                }
                if loading, mode == 0 { ProgressView("Loading preview…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 3) {
                if preview.truncated { Text("Preview limited to 256 KiB. Open the file to read all text.") }
                if rendered?.limited == true { Text("Rendered preview limited. The Markdown file remains complete.") }
                if rendered?.hasLiteralHTML == true { Text("HTML is shown as text in the preview.") }
                if rendered?.hasUnsupportedMarkup == true { Text("Some Markdown extensions are shown as text.") }
                if rendered?.unavailableImageCount ?? 0 > 0 || imageFailed { Text("Some images are unavailable in the preview.") }
                if target != nil, validTarget == nil || (mode == 0 && rendered != nil && validTarget.flatMap { rendered?.anchor(for: $0) } == nil) {
                    Text("The preview position cannot be verified or is outside this excerpt.")
                }
                if matchMissing, !query.isEmpty { Text("No match in this preview.") }
                Text("Links are inactive in the preview.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: query) { _ in find(backwards: false) }
        .sheet(item: $selectedFile) { file in
            LocalFilePreviewPane(path: file.path, assets: assets)
        }
        .task(id: preview.id) {
            loading = true; imageFailed = false; matchMissing = false
            let result = result, text = preview.text
            let unavailable = NSLocalizedString("Image unavailable in preview", comment: "")
            let limit = NSLocalizedString("Rendered preview limited", comment: "")
            let metadata = NSLocalizedString("Document metadata", comment: "")
            let language = Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true ? "de" : "en"
            let prepared = await Task.detached(priority: .userInitiated) {
                let assets = try? PreviewAssets(outputDirectory: result.outputDirectory, assets: result.assets)
                return (RenderedMarkdownPreview.render(text, assets: assets, imageUnavailable: unavailable, limitMessage: limit, metadataTitle: metadata, language: language), assets)
            }.value
            guard !Task.isCancelled else { return }
            rendered = prepared.0; assets = prepared.1; loading = false
        }
    }

    private var modePicker: some View {
        Picker("Preview view", selection: $mode) {
            Text("Rendered").tag(0)
            Text("Markdown").tag(1)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
    }
    @ViewBuilder private var searchControls: some View {
        Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
            .keyboardShortcut("f", modifiers: .command).help("Find in preview").accessibilityLabel(Text("Find in preview"))
        TextField("Find in preview", text: $query)
            .textFieldStyle(.roundedBorder).frame(minWidth: 130, maxWidth: 220)
            .focused($searchFocused)
            .onSubmit { find(backwards: false) }
        Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }
            .help("Previous match").accessibilityLabel(Text("Previous match")).disabled(query.isEmpty)
        Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }
            .help("Next match").accessibilityLabel(Text("Next match")).disabled(query.isEmpty)
    }

    private var validTarget: ConversionTextRange? {
        guard let target, target.file == result.markdownFile.lastPathComponent, preview.matchesExpectedOutput == true,
              target.utf8Offset >= 0, target.utf8Length >= 0, target.utf8Offset <= preview.text.utf8.count,
              target.utf8Length <= preview.text.utf8.count - target.utf8Offset else { return nil }
        return target
    }
    private func find(backwards: Bool) {
        self.backwards = backwards; searchRequest += 1
    }
}

private struct LocalFileSelection: Identifiable {
    let path: String
    var id: String { path }
}

private struct LocalFilePreviewPane: View {
    let path: String
    let assets: PreviewAssets?
    @Environment(\.dismiss) private var dismiss
    @State private var content: LocalFilePreview?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: path).font(.headline).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if failed {
                Text("This local file is unavailable or exceeds the preview limit.")
            } else if let content {
                switch content {
                case .image(let data), .pdf(let data, _):
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if case .pdf(_, let count) = content {
                        Text(String(format: NSLocalizedString("PDF preview: page 1 of %d. Links and actions are inactive.", comment: ""), count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .text(let text, let truncated):
                    ScrollView([.horizontal, .vertical]) { Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    if truncated { Text("Preview limited to 256 KiB. Open the file to read all text.").font(.caption) }
                case .unsupported:
                    Text("No safe preview is available for this file type. The original attachment remains in the output folder.")
                }
            } else { ProgressView("Loading preview…") }
        }
        .padding(20).frame(minWidth: 440, idealWidth: 620, minHeight: 340, idealHeight: 500, alignment: .topLeading)
        .task(id: path) {
            let assets = assets, path = path
            let result = await Task.detached(priority: .userInitiated) { try? assets?.previewFile(path) }.value
            guard !Task.isCancelled else { return }
            content = result; failed = result == nil
        }
    }
}

/// Ein einziges Suchfeld behält den Fokus auch beim Umbruch. Zwei gleichzeitig
/// vermessene FocusState-Bindungen in ViewThatFits können ältere SwiftUI-
/// Bedienungshilfen in einen zyklischen Präferenzgraphen führen.
private struct PreviewToolbarLayout: Layout {
    private let gap: CGFloat = 10
    private func metrics(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, mode: CGSize, search: CGSize, stacked: Bool) {
        let mode = subviews[0].sizeThatFits(.unspecified)
        let minimum = subviews[1].sizeThatFits(.zero)
        let ideal = subviews[1].sizeThatFits(.unspecified)
        let proposed = width.flatMap { $0.isFinite ? $0 : nil }
        let width = max(max(mode.width, minimum.width), proposed ?? (mode.width + gap + ideal.width))
        let stacked = mode.width + gap + minimum.width > width
        let searchWidth = max(minimum.width, stacked ? width : width - mode.width - gap)
        let search = subviews[1].sizeThatFits(ProposedViewSize(width: searchWidth, height: nil))
        return (width, mode, search, stacked)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let value = metrics(proposal.width, subviews)
        return CGSize(width: value.width, height: value.stacked ? value.mode.height + gap + value.search.height : max(value.mode.height, value.search.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let value = metrics(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(value.mode))
        let point = CGPoint(x: value.stacked ? bounds.minX : bounds.maxX - value.search.width,
                            y: value.stacked ? bounds.minY + value.mode.height + gap : bounds.minY)
        subviews[1].place(at: point, anchor: .topLeading, proposal: ProposedViewSize(value.search))
    }
}

private struct PreviewSourceView: NSViewRepresentable {
    let text: String
    let query: String
    let request: Int
    let backwards: Bool
    let target: ConversionTextRange?
    let targetRequest: Int
    let missing: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.documentView = view
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let changed = view.string != text
        if changed { view.string = text; context.coordinator.lastRequest = -1 }
        if context.coordinator.target != target || context.coordinator.targetRequest != targetRequest, let target,
           let selection = Self.selection(target, in: text) {
            view.setSelectedRange(selection); view.scrollRangeToVisible(selection)
        } else if target == nil, context.coordinator.target != nil {
            view.setSelectedRange(NSRange(location: view.selectedRange().location, length: 0))
        }
        context.coordinator.target = target
        context.coordinator.targetRequest = targetRequest
        guard context.coordinator.lastRequest != request else { return }
        context.coordinator.lastRequest = request
        guard !query.isEmpty else { return }
        let source = text as NSString
        let actual = view.selectedRange()
        let selection = actual.location != NSNotFound && actual.location <= source.length && actual.length <= source.length - actual.location ? actual : NSRange(location: 0, length: 0)
        let start = backwards ? selection.location : min(source.length, NSMaxRange(selection))
        let options: NSString.CompareOptions = backwards ? [.caseInsensitive, .backwards] : [.caseInsensitive]
        let range = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: source.length - start)
        var found = source.range(of: query, options: options, range: range)
        if found.location == NSNotFound { found = source.range(of: query, options: options) }
        if found.location != NSNotFound, NSMaxRange(found) <= source.length {
            view.setSelectedRange(found); view.scrollRangeToVisible(found)
        }
        let absent = found.location == NSNotFound
        DispatchQueue.main.async { missing(absent) }
    }
    private static func selection(_ target: ConversionTextRange, in text: String) -> NSRange? {
        let data = Data(text.utf8)
        guard target.text(in: data) != nil else { return nil }
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: target.utf8Offset)
        let end = text.utf8.index(start, offsetBy: target.utf8Length)
        guard let lower = String.Index(start, within: text), let upper = String.Index(end, within: text) else { return nil }
        return NSRange(lower..<upper, in: text)
    }
    final class Coordinator {
        var lastRequest = -1
        var target: ConversionTextRange?
        var targetRequest = -1
    }
}

private struct PreviewWebView: NSViewRepresentable {
    let rendered: RenderedMarkdownPreview
    let assets: PreviewAssets?
    let query: String
    let request: Int
    let backwards: Bool
    let anchor: String?
    let anchorRequest: Int
    let missing: (Bool) -> Void
    let imageFailed: () -> Void
    func makeCoordinator() -> PreviewWebCoordinator { PreviewWebCoordinator() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onMissing = missing
        context.coordinator.onImageFailed = imageFailed
        context.coordinator.update(view, rendered: rendered, assets: assets, query: query, request: request, backwards: backwards, anchor: anchor, anchorRequest: anchorRequest)
    }
}

@MainActor final class PreviewWebCoordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    var onMissing: (Bool) -> Void = { _ in }
    var onImageFailed: () -> Void = {}
    private var assets: PreviewAssets?
    private var html: String?
    private var loaded = false
    private var query = ""
    private var request = -1
    private var backwards = false
    private var anchor: String?
    private var anchorRequest = -1
    private var active = Set<ObjectIdentifier>()
    private var failedImages = Set<URL>()
    private var generation = 0
    private let queue = DispatchQueue(label: "org.poormanstext.preview-images", qos: .userInitiated)

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.setURLSchemeHandler(self, forURLScheme: "pmt-preview")
        let view = PreviewWebContentView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.underPageBackgroundColor = .textBackgroundColor
        view.viewportChanged = { [weak self, weak view] in
            guard let self, self.loaded, let view else { return }
            self.scroll(in: view)
        }
        return view
    }
    func update(_ view: WKWebView, rendered: RenderedMarkdownPreview, assets: PreviewAssets?, query: String, request: Int, backwards: Bool, anchor: String?, anchorRequest: Int = 0) {
        let newDocument = html != rendered.html || self.assets?.token != assets?.token
        let newSearch = self.request != request || self.query != query
        let newAnchor = self.anchor != anchor || self.anchorRequest != anchorRequest
        self.assets = assets; self.query = query; self.request = request; self.backwards = backwards; self.anchor = anchor
        self.anchorRequest = anchorRequest
        if newDocument {
            generation += 1
            html = rendered.html; loaded = false; failedImages = []
            view.loadHTMLString(rendered.html, baseURL: nil)
        } else if loaded {
            if newSearch { find(in: view) }
            if newAnchor { scroll(in: view) }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true; find(in: webView); scroll(in: webView)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    private func find(in view: WKWebView) {
        let configuration = WKFindConfiguration(); configuration.backwards = backwards; configuration.wraps = true
        let expected = query
        let generation = generation, request = request
        view.find(query, configuration: configuration) { [weak self] result in
            guard let self, self.query == expected, self.generation == generation, self.request == request else { return }
            self.onMissing(!expected.isEmpty && !result.matchFound)
        }
    }
    private func scroll(in view: WKWebView) {
        guard let anchor, anchor.hasPrefix("pmt-"), Int(anchor.dropFirst(4)) != nil,
              let encoded = try? JSONEncoder().encode(anchor), let literal = String(data: encoded, encoding: .utf8) else { return }
        // Ausschließlich eigener Code mit einer erzeugten, als JSON kodierten ID.
        view.evaluateJavaScript("document.getElementById(\(literal))?.scrollIntoView({block:'center',inline:'nearest'})", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        active.insert(id)
        let request = SchemeRequest(task: urlSchemeTask)
        let url = urlSchemeTask.request.url
        let assets = assets
        queue.async { [weak self] in
            let result: Result<Data, Error> = Result {
                guard let url, let assets else { throw PreviewAssetError.unavailable }
                return try assets.thumbnail(for: url)
            }
            Task { @MainActor [weak self] in
                guard let self, self.active.remove(id) != nil else { return }
                guard self.assets?.token == url?.host else { request.task.didFailWithError(PreviewAssetError.unavailable); return }
                switch result {
                case .success(let data):
                    guard let url else { return }
                    request.task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                    request.task.didReceive(data); request.task.didFinish()
                case .failure(let error):
                    request.task.didFailWithError(error)
                    if let url, self.failedImages.insert(url).inserted { self.onImageFailed() }
                }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { active.remove(ObjectIdentifier(urlSchemeTask)) }
    private final class SchemeRequest: @unchecked Sendable {
        let task: any WKURLSchemeTask
        init(task: any WKURLSchemeTask) { self.task = task }
    }
}

private final class PreviewWebContentView: WKWebView {
    var viewportChanged: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            Task { @MainActor [weak self] in self?.viewportChanged?() }
        }
    }
}
