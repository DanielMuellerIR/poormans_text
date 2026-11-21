import Foundation
import XCTest
@testable import PoorMansTextCore

final class TextbundleOutputRegressionTests: XCTestCase {
    /// Assetnamen stehen im Markdown prozentkodiert, auf der Platte aber roh.
    /// Der Rewriter verglich nur wörtlich, verfehlte solche Links und das
    /// Textbundle verschob das Bild nach `assets/`, ohne den Link mitzunehmen —
    /// das Bild war still weg.
    func testTextbundleRewritesPercentEncodedAssetLinks() throws {
        let root = try makeRegressionDirectory()
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        let images = staged.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("PNG".utf8).write(to: images.appendingPathComponent("image01.pn+g"))
        try Data("Text\n\n![Beispiel](images/image01.pn%2Bg)\n".utf8)
            .write(to: staged.appendingPathComponent("Seite.md"))

        let layout = try ConversionPostprocessor.applyTextbundleLayout(
            in: staged,
            markdownRelativePath: "Seite.md",
            assetRelativePaths: ["images/image01.pn+g"],
            fileManager: .default
        )

        XCTAssertEqual(layout.assets, ["assets/image01.pn+g"])
        let markdown = try String(contentsOf: staged.appendingPathComponent("text.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("![Beispiel](assets/image01.pn%2Bg)"), markdown)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.appendingPathComponent("assets/image01.pn+g").path)
        )
    }

    /// Ein roher Name bleibt roh — die Kodierung wird nur dort ergänzt, wo der
    /// gefundene Link selbst kodiert war.
    func testARawAssetLinkIsRewrittenWithoutEncoding() {
        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: "![x](images/bild a.png)", from: "images/bild a.png", to: "assets/bild a.png"
            ),
            "![x](images/bild a.png)"
        )
        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: "![x](<images/bild a.png>)", from: "images/bild a.png", to: "assets/bild a.png"
            ),
            "![x](<assets/bild a.png>)"
        )
    }

    /// Ein Ziel namens `*.textbundle` ohne Textbundle-Ablage ergab einen Ordner
    /// ohne `info.json` und `text.md`, den der Finder trotzdem für ein Paket hält.
    func testAnOutputNamedTextbundleNeedsTheTextbundleLayout() throws {
        let root = try makeRegressionDirectory()
        let sourceURL = root.appendingPathComponent("Tabelle.ods")
        try RegressionFixtures.ods(meta: "<dc:title>Titel</dc:title>").write(to: sourceURL)
        let target = root.appendingPathComponent("Notiz.textbundle", isDirectory: true)

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: sourceURL, destination: .directory(target))
            )
        ) { error in
            guard case ConversionError.invalidOutputName = error else {
                return XCTFail("unerwarteter Fehler: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // Mit der passenden Ablage entsteht das Bundle wie gehabt.
        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(target),
                options: ConversionOptions(outputLayout: .textbundle)
            )
        )
        XCTAssertEqual(result.markdownFile.lastPathComponent, "text.md")
    }

    func testTextbundleUsesOneMappingAndHonorsCancellation() throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let markdown = "![a](images/first.png) ![b](images/second%20photo.png)"
            try Data(markdown.utf8).write(to: root.appendingPathComponent("body.md"))
            for name in ["first.png", "second photo.png"] { try Data([1]).write(to: root.appendingPathComponent("images/" + name)) }
            let token = ConversionCancellationToken()
            if cancel { token.cancel() }
            let context = ConversionExecution.Context(cancellation: token, progress: nil, processTimeout: nil)
            let operation = {
                try ConversionExecution.$current.withValue(context) {
                    try ConversionPostprocessor.applyTextbundleLayout(in: root, markdownRelativePath: "body.md",
                        assetRelativePaths: ["images/first.png", "images/second photo.png"], fileManager: .default)
                }
            }
            if cancel {
                XCTAssertThrowsError(try operation())
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("text.md").path))
            } else {
                _ = try operation()
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("text.md"), encoding: .utf8),
                               "![a](assets/first.png) ![b](assets/second%20photo.png)")
            }
        }
    }
}
