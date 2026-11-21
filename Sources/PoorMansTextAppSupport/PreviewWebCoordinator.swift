import AppKit
import WebKit

@MainActor
package final class PreviewWebCoordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    package var onMissing: (Bool) -> Void = { _ in }
    package var onImageFailed: () -> Void = {}
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

    package override init() { super.init() }

    package func makeWebView() -> WKWebView {
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
    package func update(
        _ view: WKWebView, rendered: RenderedMarkdownPreview, assets: PreviewAssets?, query: String,
        request: Int, backwards: Bool, anchor: String?, anchorRequest: Int = 0
    ) {
        let newDocument = html != rendered.html || self.assets?.token != assets?.token
        let newSearch = self.request != request || self.query != query
        let newAnchor = self.anchor != anchor || self.anchorRequest != anchorRequest
        self.assets = assets
        self.query = query
        self.request = request
        self.backwards = backwards
        self.anchor = anchor
        self.anchorRequest = anchorRequest
        if newDocument {
            generation += 1
            html = rendered.html
            loaded = false
            failedImages = []
            view.loadHTMLString(rendered.html, baseURL: nil)
        } else if loaded {
            if newSearch { find(in: view) }
            if newAnchor { scroll(in: view) }
        }
    }
    package func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        find(in: webView)
        scroll(in: webView)
    }
    package func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        decisionHandler(url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    private func find(in view: WKWebView) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        let expected = query
        let generation = generation, request = request
        view.find(query, configuration: configuration) { [weak self] result in
            guard let self, self.query == expected, self.generation == generation, self.request == request
            else { return }
            self.onMissing(!expected.isEmpty && !result.matchFound)
        }
    }
    private func scroll(in view: WKWebView) {
        guard let anchor, anchor.hasPrefix("pmt-"), Int(anchor.dropFirst(4)) != nil,
            let encoded = try? JSONEncoder().encode(anchor),
            let literal = String(data: encoded, encoding: .utf8)
        else { return }
        // Ausschließlich eigener Code mit einer erzeugten, als JSON kodierten ID.
        view.evaluateJavaScript(
            "document.getElementById(\(literal))?.scrollIntoView({block:'center',inline:'nearest'})",
            completionHandler: nil)
    }
    package func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
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
                guard self.assets?.token == url?.host else {
                    request.task.didFailWithError(PreviewAssetError.unavailable)
                    return
                }
                switch result {
                case .success(let data):
                    guard let url else { return }
                    request.task.didReceive(
                        URLResponse(
                            url: url, mimeType: "image/png", expectedContentLength: data.count,
                            textEncodingName: nil))
                    request.task.didReceive(data)
                    request.task.didFinish()
                case .failure(let error):
                    request.task.didFailWithError(error)
                    if let url, self.failedImages.insert(url).inserted { self.onImageFailed() }
                }
            }
        }
    }
    package func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }
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
