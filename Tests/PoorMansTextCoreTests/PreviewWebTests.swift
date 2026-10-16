import AppKit
import WebKit
import XCTest
@testable import PoorMansTextAppSupport

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
