import AppKit
import WebKit
import XCTest
@testable import PoorMansTextAppSupport
@testable import PoorMansTextCore

@MainActor final class PreviewWebTests: XCTestCase {
    func testRealWebKitLoadsOnlyApprovedImagesAndKeepsHTMLAndScriptsInactive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTWebPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = root.appendingPathComponent("picture.png")
        let original = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
        try original.write(to: asset)
        let assets = try PreviewAssets(outputDirectory: root, assets: [asset])
        let rendered = RenderedMarkdownPreview.render("# PreviewMarker🙂\n\n![Picture](picture.png)\n\n| Name | Value |\n| --- | --- |\n| TableMarker | 42 |\n\n<script>window.bad=1</script>\n\n![Remote](https://example.invalid/tracker.png)\n\n[Link](https://example.invalid/)\n", assets: assets)
        let coordinator = PreviewWebCoordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 520)
        coordinator.update(view, rendered: rendered, assets: assets, query: "", request: 0, backwards: false, anchor: nil)
        try await waitUntil { try await self.value("document.querySelector('h1')?.textContent ?? ''", in: view) == "PreviewMarker🙂" }
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let activeElements = try await value("String(document.querySelectorAll('script,iframe,a[href]').length)", in: view)
        let injectedValue = try await value("typeof window.bad", in: view)
        let rows = try await value("String(document.querySelectorAll('table tbody tr').length)", in: view)
        let images = try await value("String(document.images.length)", in: view)
        XCTAssertEqual(activeElements, "0"); XCTAssertEqual(injectedValue, "undefined")
        XCTAssertEqual(rows, "1"); XCTAssertEqual(images, "1")
        _ = try await value("document.images[0].loading='eager'; 'ready'", in: view)
        try await waitUntil { try await self.value("String(document.images[0].naturalWidth > 0)", in: view) == "true" }
        let localResourcesOnly = try await value("String(performance.getEntriesByType('resource').every(x => x.name.startsWith('pmt-preview:')))", in: view)
        XCTAssertEqual(localResourcesOnly, "true")
        XCTAssertEqual(try Data(contentsOf: asset), original)
        XCTAssertTrue(coordinator.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
    }

    func testNativeFindAndKnownAnchorWorkWithContentJavaScriptDisabled() async throws {
        let rendered = RenderedMarkdownPreview.render("# SearchMarker\n\nFirst Needle\n\n" + String(repeating: "Filler paragraph.\n\n", count: 80) + "## LastMarker\n\nSecond Needle\n", assets: nil)
        let coordinator = PreviewWebCoordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 420)
        coordinator.update(view, rendered: rendered, assets: nil, query: "", request: 0, backwards: false, anchor: nil)
        try await waitUntil { try await self.value("document.querySelector('h1')?.textContent ?? ''", in: view) == "SearchMarker" }
        let result = await withCheckedContinuation { continuation in
            view.find("Needle", configuration: WKFindConfiguration()) { continuation.resume(returning: $0.matchFound) }
        }
        XCTAssertTrue(result)
        let last = try XCTUnwrap(rendered.anchors.last)
        coordinator.update(view, rendered: rendered, assets: nil, query: "", request: 1, backwards: false, anchor: last.id)
        try await waitUntil { try await self.value("String(window.scrollY > 0)", in: view) == "true" }
        let lastText = try await value("document.getElementById('\(last.id)')?.textContent ?? ''", in: view)
        XCTAssertEqual(lastText, "Second Needle")
        _ = try await value("window.scrollTo(0,0); 'reset'", in: view)
        coordinator.update(view, rendered: rendered, assets: nil, query: "", request: 1, backwards: false, anchor: last.id, anchorRequest: 1)
        try await waitUntil { try await self.value("String(window.scrollY > 0)", in: view) == "true" }
        _ = try await value("window.scrollTo(0,0); 'reset'", in: view)
        view.setFrameSize(NSSize(width: 400, height: 200))
        try await waitUntil { try await self.value("String(window.scrollY > 0)", in: view) == "true" }
    }

    func testRealWebKitSnapshotsHaveVisibleContentInLightAndDark() async throws {
        let rendered = RenderedMarkdownPreview.render("# Preview title🙂\n\nA readable paragraph with **bold** and *emphasis*.\n\n- First item\n- Second item\n\n| Name | Value |\n| --- | ---: |\n| Table marker | 42 |\n\n```swift\nlet example = \"Unicode Grüße\"\n```\n\n> A short quotation.\n", assets: nil)
        let coordinator = PreviewWebCoordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 560)
        coordinator.update(view, rendered: rendered, assets: nil, query: "", request: 0, backwards: false, anchor: nil)
        try await waitUntil { try await self.value("document.querySelector('h1')?.textContent ?? ''", in: view) == "Preview title🙂" }
        var backgrounds: [String] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(150))
            backgrounds.append(try await value("getComputedStyle(document.body).backgroundColor", in: view))
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                view.takeSnapshot(with: nil) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                            let png = bitmap.representation(using: .png, properties: [:]) { continuation.resume(returning: png) }
                    else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                }
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            var colors = Set<Int>()
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                    }
                }
            }
            XCTAssertGreaterThan(colors.count, 10, "The WebKit snapshot is blank")
            if let path = ProcessInfo.processInfo.environment["POORMANS_TEXT_PREVIEW_EVIDENCE"] {
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("rendered-\(name).png"))
            }
        }
        XCTAssertEqual(backgrounds.count, 2)
        XCTAssertNotEqual(backgrounds[0], backgrounds[1])
    }

    func testPresentationLinksRenderInRealWebKitWithoutActiveNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTPresentationPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["pptx", "odp"] {
            let source = root.appendingPathComponent("linked.\(ext)")
            try PresentationLinkFixture.data(ext: ext).write(to: source)
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(ext))))
            let assets = try PreviewAssets(outputDirectory: result.outputDirectory, assets: result.assets)
            let rendered = RenderedMarkdownPreview.render(try String(contentsOf: result.markdownFile, encoding: .utf8), assets: assets)
            let coordinator = PreviewWebCoordinator(); let view = coordinator.makeWebView()
            view.frame = NSRect(x: 0, y: 0, width: 740, height: 780)
            coordinator.update(view, rendered: rendered, assets: assets, query: "", request: 0, backwards: false, anchor: nil)
            try await waitUntil { try await self.value("String(document.querySelectorAll('.preview-link').length)", in: view) == "7" }
            let active = try await value("String(document.querySelectorAll('a[href],script,iframe').length)", in: view)
            let anchors = try await value("String(!!document.getElementById('pmt-slide-1') && !!document.getElementById('pmt-slide-2'))", in: view)
            let target = try await value("Array.from(document.querySelectorAll('.preview-link')).find(x=>x.textContent.includes('JUMP_LABEL'))?.title ?? ''", in: view)
            XCTAssertEqual(active, "0"); XCTAssertEqual(anchors, "true"); XCTAssertEqual(target, "#pmt-slide-2")
            let noteText = try await value("document.querySelector('blockquote')?.textContent ?? ''", in: view)
            XCTAssertEqual(noteText.trimmingCharacters(in: .whitespacesAndNewlines), "NOTE_WEB NOTE_JUMP", ext)
            XCTAssertFalse(rendered.hasLiteralHTML); XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                view.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(150))
                let snapshot: Data = try await withCheckedThrowingContinuation { continuation in
                    view.takeSnapshot(with: nil) { image, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { continuation.resume(returning: png) }
                        else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                    }
                }
                if let path = ProcessInfo.processInfo.environment["PMT_PRESENTATION_PREVIEW_DIR"] {
                    try snapshot.write(to: URL(fileURLWithPath: path).appendingPathComponent("presentation-\(ext)-\(name).png"))
                }
            }
        }
    }

    func testLargePreviewReportsAnAbsentSearchResult() async throws {
        let rendered = RenderedMarkdownPreview.render("# LargeMarker\n\n" + String(repeating: "Searchable paragraph.\n\n", count: 7500), assets: nil)
        let coordinator = PreviewWebCoordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 420)
        coordinator.update(view, rendered: rendered, assets: nil, query: "", request: 0, backwards: false, anchor: nil)
        try await waitUntil { try await self.value("document.querySelector('h1')?.textContent ?? ''", in: view) == "LargeMarker" }
        var missing = false
        coordinator.onMissing = { missing = $0 }
        coordinator.update(view, rendered: rendered, assets: nil, query: "AbsentMarker", request: 1, backwards: false, anchor: nil)
        try await waitUntil { missing }
    }

    func testPDFAnnotationsHaveSafeNativePreviewAndExactSourceResultJump() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTPDFPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try PDFAnnotationFixture.make(in: root)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(pdfTextRecognition: .disabled,conversionReport: true)))
        let text = try String(contentsOf: result.markdownFile,encoding: .utf8)
        let rendered = RenderedMarkdownPreview.render(text,assets: nil)
        let location = ConversionLocation(page: 1,note: "Annotation 4")
        let target = try XCTUnwrap(ComparisonNavigation.target(for: location,mappings: result.sourceMappings))
        XCTAssertTrue(target.exact)
        XCTAssertTrue(target.range.text(in: Data(text.utf8))?.contains("COMMENT") == true)
        let anchor = try XCTUnwrap(rendered.anchor(for: target.range))
        let snapshot = try ComparisonSourceSnapshot.read(result), sourceRenderer = ComparisonSourceRenderer(snapshot)
        let pages = try await sourceRenderer.prepare()
        XCTAssertEqual(pages,2)
        let sourcePage = try await sourceRenderer.render(try XCTUnwrap(location.page))
        let secondPage = try await sourceRenderer.render(2)
        XCTAssertFalse(sourcePage.isEmpty); XCTAssertNotEqual(sourcePage,secondPage)
        let coordinator = PreviewWebCoordinator(), view = coordinator.makeWebView()
        view.frame = NSRect(x: 0,y: 0,width: 740,height: 620)
        coordinator.update(view,rendered: rendered,assets: nil,query: "",request: 0,backwards: false,anchor: nil)
        try await waitUntil { try await self.value("String(document.querySelectorAll('.preview-link').length)",in: view) == "2" }
        let active = try await value("String(document.querySelectorAll('a[href],script,iframe,img').length)",in: view)
        let pageAnchors = try await value("String(!!document.getElementById('pmt-pdf-page-1') && !!document.getElementById('pmt-pdf-page-2'))",in: view)
        XCTAssertEqual(active,"0"); XCTAssertEqual(pageAnchors,"true")
        XCTAssertFalse(rendered.hasLiteralHTML); XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            for (state,jump) in [("overview",false),("comment",true)] {
                _ = try await value("window.scrollTo(0,0); 'reset'",in: view)
                if jump {
                    coordinator.update(view,rendered: rendered,assets: nil,query: "",request: 0,backwards: false,anchor: anchor.id,anchorRequest: name == "light" ? 1 : 2)
                    try await waitUntil { try await self.value("String(window.scrollY > 0 && document.getElementById('\(anchor.id)').getBoundingClientRect().top >= 0 && document.getElementById('\(anchor.id)').getBoundingClientRect().bottom <= window.innerHeight)",in: view) == "true" }
                    let heading = try await value("document.getElementById('\(anchor.id)')?.textContent ?? ''",in: view)
                    XCTAssertEqual(heading,"Annotation 4")
                }
                try await Task.sleep(for: .milliseconds(150))
                if let path = ProcessInfo.processInfo.environment["PMT_PDF_PREVIEW_DIR"] {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        view.takeSnapshot(with: nil) { image,error in
                            if let error { continuation.resume(throwing: error) }
                            else if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),let png = bitmap.representation(using: .png,properties: [:]) { continuation.resume(returning: png) }
                            else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                        }
                    }
                    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("pdf-\(state)-\(name).png"))
                }
            }
        }
    }

    private func value(_ script: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? String ?? String(describing: value ?? "nil")) }
            }
        }
    }
    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if (try? await predicate()) == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("The real WebKit preview did not reach the expected state")
        throw CocoaError(.coderInvalidValue)
    }
}
