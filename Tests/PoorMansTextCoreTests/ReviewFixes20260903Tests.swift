import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport
@testable import PoorMansTextCore

/// Regressionen für die Funde des Nacht-Reviews vom 2026-09-03.
final class ReviewFixes20260903Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0903-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - HTMLImageSourceResolver

    private func resolve(
        _ html: String,
        baseDirectory: URL? = nil,
        baseURL: URL? = nil,
        subresources: [String: HTMLImageSourceResolver.Subresource] = [:]
    ) throws -> HTMLImageSourceResolver.Resolution {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        return try HTMLImageSourceResolver.resolve(
            html: html,
            baseDirectory: baseDirectory,
            baseURL: baseURL,
            subresources: subresources,
            workDirectory: work
        )
    }

    func testActiveAndUnknownSchemesNeverBecomeLinksEvenWithAWebBase() throws {
        let html = """
        <img src="javascript:alert(1)" alt="Skript">
        <img src="vbscript:x" alt="Alt">
        <img src="mailto:a@b.c" alt="Mail">
        <img src="https://example.com/x.png" alt="Bild">
        """
        let resolution = try resolve(html, baseURL: URL(string: "https://example.com/seite.html"))

        XCTAssertEqual(resolution.remoteImagesKeptAsLinks, 1)
        XCTAssertEqual(resolution.missingImagesDropped, 3)
        XCTAssertFalse(resolution.html.contains("javascript:"), resolution.html)
        XCTAssertFalse(resolution.html.contains("vbscript:"), resolution.html)
        XCTAssertTrue(resolution.html.contains("<a href=\"https://example.com/x.png\">Bild</a>"), resolution.html)
    }

    func testAFIFONextToTheSourceIsNotAnImageAndDoesNotBlock() throws {
        let fifo = root.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let resolution = try resolve("<img src=\"pipe.png\" alt=\"Pipe\">", baseDirectory: root)

        XCTAssertEqual(resolution.missingImagesDropped, 1)
        XCTAssertEqual(resolution.html, "Pipe")
    }

    func testALocalImageIsCopiedThroughTheVerifiedStagingPath() throws {
        try Data("png-bytes".utf8).write(to: root.appendingPathComponent("bild.png"))

        let resolution = try resolve("<img src=\"bild.png\" alt=\"Bild\">", baseDirectory: root)

        XCTAssertEqual(resolution.html, "<img src=\"external/local01.png\" alt=\"Bild\">")
        XCTAssertEqual(resolution.missingImagesDropped, 0)
    }

    func testUnquotedAttributesAreReadLikeQuotedOnes() throws {
        try Data("png-bytes".utf8).write(to: root.appendingPathComponent("bild.png"))

        let resolution = try resolve("<img src=bild.png alt=Bild>", baseDirectory: root)

        XCTAssertEqual(resolution.html, "<img src=\"external/local01.png\" alt=Bild>")
        XCTAssertEqual(resolution.missingImagesDropped, 0)

        let remote = try resolve("<img src=https://example.com/x.png alt=Fern>")
        XCTAssertEqual(remote.html, "<a href=\"https://example.com/x.png\">Fern</a>")
    }

    func testALocallySavedWebArchiveFindsItsFileSubresources() throws {
        let subresources = [
            "file:///Users/x/Seite_files/a.png": HTMLImageSourceResolver.Subresource(data: Data("a".utf8), mimeType: "image/png"),
            "file:///Users/x/b.png": HTMLImageSourceResolver.Subresource(data: Data("b".utf8), mimeType: "image/png"),
        ]
        let html = """
        <img src="Seite_files/a.png" alt="Relativ">
        <img src="file:///Users/x/b.png" alt="Absolut">
        <img src="file:///Users/x/fehlt.png" alt="Fehlt">
        """
        let resolution = try resolve(html, baseURL: URL(string: "file:///Users/x/Seite.html"), subresources: subresources)

        XCTAssertTrue(resolution.html.contains("<img src=\"external/resource01.png\" alt=\"Relativ\">"), resolution.html)
        XCTAssertTrue(resolution.html.contains("<img src=\"external/resource02.png\" alt=\"Absolut\">"), resolution.html)
        XCTAssertTrue(resolution.html.contains("Fehlt"), resolution.html)
        XCTAssertFalse(resolution.html.contains("file:///Users/x/fehlt.png"), resolution.html)
        XCTAssertEqual(resolution.missingImagesDropped, 1)
        XCTAssertEqual(resolution.remoteImagesKeptAsLinks, 0)
    }

    // MARK: - RTF-Metadaten

    func testRTFUnicodeHonoursTheFallbackCountAndSurrogatePairs() {
        // U+1F389 (🎉) als Surrogatpaar D83C DF89 → -10180, -8311; `\uc2` verlangt
        // zwei Ersatzzeichen nach jedem `\uN`.
        let rtf = #"{\rtf1\ansi{\info{\title \uc2\u-10180 ??\u-8311 ?? Fest}{\subject \uc0\u8364 x}{\author \u8364 ?x\u228\'e4y}}}"#
        let metadata = RTFInfoParser.parse(Data(rtf.utf8))

        XCTAssertEqual(metadata.title, "🎉 Fest")
        XCTAssertEqual(metadata.subject, "€x")
        XCTAssertEqual(metadata.author, "€xäy")
    }

    // MARK: - CSV/TSV

    func testUTF16WithHalfACharacterIsRejectedInFullConversionButToleratedWhenTruncated() throws {
        let odd = Data([0xFF, 0xFE, 0x41, 0x00, 0x42])

        XCTAssertEqual(try DelimitedTextDecoder.decode(odd, truncated: true).text, "A")
        XCTAssertThrowsError(try DelimitedTextDecoder.decode(odd, truncated: false))

        let sourceURL = root.appendingPathComponent("halb.csv")
        try odd.write(to: sourceURL)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))) { error in
            guard case ConversionError.invalidInput(_, let format, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(format, .csv)
            XCTAssertTrue(reason.contains("half a character"), reason)
        }
    }

    func testAQuotedFieldLeftOpenAtTheEndIsASyntaxError() throws {
        XCTAssertThrowsError(try DelimitedTextParser.parse("\"a,b", delimiter: ","))
        XCTAssertThrowsError(try DelimitedTextParser.parse("x,y\n\"offen", delimiter: ","))
        XCTAssertEqual(try DelimitedTextParser.parse("\"a\",b", delimiter: ",").count, 1)

        let sourceURL = root.appendingPathComponent("offen.csv")
        try Data("a,b\n\"nie zu".utf8).write(to: sourceURL)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))) { error in
            guard case ConversionError.invalidInput(_, _, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("quoted field"), reason)
        }
    }

    // MARK: - App

    @MainActor
    func testADropReservesTheAppUntilItsFilesAreLoaded() async throws {
        let inputURL = root.appendingPathComponent("Eins.csv")
        try Data("a,b\n1,2\n".utf8).write(to: inputURL)
        let model = AppModel()
        model.imageTextRecognition = .disabled

        XCTAssertTrue(model.acceptDrop([NSItemProvider(object: inputURL as NSURL)]))
        // Noch vor dem ersten `await` ist die App belegt: Ein zweiter Drop
        // wird abgelehnt statt später stumm verworfen.
        XCTAssertFalse(model.acceptsNewDocuments)
        XCTAssertFalse(model.acceptDrop([NSItemProvider(object: inputURL as NSURL)]))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .succeeded(let result) = model.state {
                XCTAssertEqual(result.format, .csv)
                XCTAssertTrue(model.acceptsNewDocuments)
                return
            }
            if case .failed(_, let message) = model.state {
                return XCTFail(message)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The dropped file did not convert within five seconds.")
    }

    // MARK: - Info.plist

    func testTheFinderServiceAcceptsEveryRegisteredDocumentContentType() throws {
        let plistURL = projectRoot.appendingPathComponent("App/Info.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let fileService = try XCTUnwrap(services.first { $0["NSSendFileTypes"] != nil })
        let sendFileTypes = Set(try XCTUnwrap(fileService["NSSendFileTypes"] as? [String]))

        // Jeder Dokumenttyp, den die App öffnet, muss auch im Finder-Dienst
        // stehen; nur `public.folder` gehört allein dem Dienst.
        XCTAssertEqual(contentTypes.subtracting(sendFileTypes), [])
        XCTAssertEqual(sendFileTypes.subtracting(contentTypes), ["public.folder"])
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
