import AppKit
import Darwin
import Foundation
import XCTest
@testable import PoorMansTextCore
import PoorMansTextAppSupport

final class CollectionOutputTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCollection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRealMailCollectionPreservesOrderDuplicateTitlesAssetsMetadataAndBothLayouts() throws {
        let fixture = try makeFixture()
        let original = try Data(contentsOf: fixture.source)
        let converter = DocumentConverter(adapters: [MailCollectionFixtureAdapter()])
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try converter.convert(.init(inputURL: fixture.source,
                destination: .directory(root.appendingPathComponent(layout == .textbundle ? "archive.textbundle" : "archive-markdown")),
                options: .init(frontmatter: true, outputLayout: layout, conversionReport: true)))
            XCTAssertTrue(result.isCollection)
            XCTAssertEqual(result.documents.map(\.sourceIndex), [1, 2, 3])
            XCTAssertEqual(result.documents.map(\.title), ["Same title", "Same title", "Grüße 🙂 [Titel]"])
            XCTAssertEqual(Set(result.documents.map(\.markdownFile)).count, 3)
            XCTAssertEqual(result.assets.count, 12)
            XCTAssertEqual(Set(result.assets).count, 12)
            XCTAssertTrue(Set(result.documents.map(\.markdownFile)).isSubset(of: Set(result.assets)))
            XCTAssertEqual(result.markdownFile.lastPathComponent, layout == .textbundle ? "text.md" : "index.md")
            let overview = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(overview.hasPrefix("---\n"))
            XCTAssertEqual(overview.components(separatedBy: "Same title").count - 1, 2)
            let rendered = RenderedMarkdownPreview.render(overview, assets: nil)
            XCTAssertFalse(rendered.html.contains("<a href="))
            XCTAssertEqual(rendered.html.components(separatedBy: "Same title").count - 1, 2)
            for (offset, document) in result.documents.enumerated() {
                let number = offset + 1
                let text = try String(contentsOf: document.markdownFile, encoding: .utf8)
                XCTAssertTrue(text.hasPrefix("---\n"))
                XCTAssertEqual(text.components(separatedBy: "DOCBODY\(number)").count - 1, 1)
                for other in (1...3) where other != number { XCTAssertFalse(text.contains("DOCBODY\(other)")) }
                XCTAssertEqual(document.assets.count, 3)
                XCTAssertEqual(document.metadata.author, "Sender <sender@example.test>")
                XCTAssertNotNil(document.metadata.created)
                let images = document.assets.filter { $0.pathExtension == "png" }
                XCTAssertEqual(images.count, 2)
                let attachment = try XCTUnwrap(document.assets.first { $0.pathExtension == "bin" })
                // Die bestehende Mail-Engine behält neben dem gerenderten Bild
                // auch den ursprünglichen MIME-Anhang. Beide Bytes gehören zum Nachweis.
                for image in images { XCTAssertEqual(try Data(contentsOf: image), fixture.image) }
                XCTAssertEqual(try Data(contentsOf: attachment), Data([UInt8(number), 0, 255]))
                XCTAssertTrue(text.contains("images/image01.png"))
                XCTAssertTrue(document.markdownFile.path.contains("/assets/documents/"))
                let mapping = try XCTUnwrap(result.sourceMappings.first { $0.source.message == "<message\(number)@example.test>" })
                let mapped = try XCTUnwrap(mapping.output.text(in: Data(text.utf8)))
                XCTAssertTrue(mapped.contains("DOCBODY\(number)"))
                XCTAssertFalse(mapped.hasPrefix("---\n"))
                XCTAssertTrue(overview.contains(MarkdownLinkTargetRewriter.percentEncodedPath(mapping.output.file)))
                let preview = try MarkdownPreview.read(document.markdownFile, expected: result.outputFiles.first { $0.path == mapping.output.file })
                XCTAssertEqual(preview.matchesExpectedOutput, true)
            }
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.documents?.map(\.sourceIndex), [1, 2, 3])
            XCTAssertEqual(report.outputs.count, layout == .textbundle ? 14 : 13)
            for file in report.outputs { XCTAssertTrue(file.matches(try Data(contentsOf: result.outputDirectory.appendingPathComponent(file.path)))) }
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
            XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        }
    }

    func testFailureInLaterMessageCancellationAndCollisionPublishNothing() throws {
        let fixture = try makeFixture()
        let original = try Data(contentsOf: fixture.source)
        let failed = root.appendingPathComponent("failed")
        XCTAssertThrowsError(try DocumentConverter(adapters: [MailCollectionFixtureAdapter(failAfter: 2)]).convert(.init(inputURL: fixture.source, destination: .directory(failed))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        let cancelled = root.appendingPathComponent("cancelled")
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter(adapters: [MailCollectionFixtureAdapter()]).convert(.init(inputURL: fixture.source, destination: .directory(cancelled)), progress: { value in
            if value.phase == .publishing { token.cancel() }
        }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("index.md"))
        XCTAssertThrowsError(try DocumentConverter(adapters: [MailCollectionFixtureAdapter()]).convert(.init(inputURL: fixture.source, destination: .directory(existing))))
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("index.md"), encoding: .utf8), "keep")
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }

    func testSingleDocumentResultRetainsPrimaryEntryAndHasOneAdditiveDocument() throws {
        let source = root.appendingPathComponent("single.csv")
        try Data("Name,Value\nONLYBODY,42\n".utf8).write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source))
        XCTAssertFalse(result.isCollection)
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents.first?.markdownFile, result.markdownFile)
        XCTAssertEqual(result.documents.first?.assets, result.assets)
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("ONLYBODY"))
    }

    func testEmptyCollectionIsDistinctFromASingleDocument() throws {
        let source = root.appendingPathComponent("empty.fixture")
        try Data("SOURCE".utf8).write(to: source)
        let result = try DocumentConverter(adapters: [CollectionContractFixture(mode: .empty)]).convert(.init(inputURL: source, options: .init(conversionReport: true)))
        XCTAssertTrue(result.isCollection)
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("No documents."))
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
        XCTAssertEqual(report.documents?.count, 0)
    }

    func testUnsafeIncompleteAndOversizedCollectionsNeverPublish() throws {
        let source = root.appendingPathComponent("guarded.fixture")
        let original = Data("SOURCE_UNCHANGED".utf8)
        try original.write(to: source)
        for mode in [CollectionContractFixture.Mode.rogue, .fifo, .symlink, .traversal, .nested, .metadataLimit, .missingAsset, .badIndex, .reservedInfo] {
            let target = root.appendingPathComponent(mode.rawValue)
            XCTAssertThrowsError(try DocumentConverter(adapters: [CollectionContractFixture(mode: mode)]).convert(.init(inputURL: source, destination: .directory(target))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), mode.rawValue)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }

    func testTextbundleBacklinksAndFinalSourceMappingsRetainLiteralCode() throws {
        let source = root.appendingPathComponent("links.fixture")
        try Data("SOURCE".utf8).write(to: source)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try DocumentConverter(adapters: [CollectionContractFixture(mode: .backlink)]).convert(.init(inputURL: source,
                destination: .directory(root.appendingPathComponent(layout == .textbundle ? "links.textbundle" : "links-markdown")),
                options: .init(frontmatter: true, outputLayout: layout, conversionReport: true)))
            let document = try XCTUnwrap(result.documents.first)
            let data = try Data(contentsOf: document.markdownFile)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains(layout == .textbundle ? "[Overview](../../../text.md)" : "[Overview](../../../index.md)"))
            XCTAssertTrue(text.contains("`[literal](../../../index.md)`"))
            let mapping = try XCTUnwrap(result.sourceMappings.first { $0.source.note == "1" })
            XCTAssertEqual(mapping.output.text(in: data), text.components(separatedBy: "---\n").last)
            XCTAssertEqual(mapping.output.utf8Offset + mapping.output.utf8Length, data.count)
        }
    }

    private func makeFixture() throws -> (source: URL, image: Data) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<2 { for x in 0..<2 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = 0; pixels[offset + 2] = 0; pixels[offset + 3] = 255
        } }
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        var entries = [ZIPFixtureBuilder.Entry(name: "count.txt", content: Data("3".utf8))]
        for number in 1...3 {
            let title = number == 3 ? "Grüße 🙂 [Titel]" : "Same title"
            let subject = "=?UTF-8?B?" + Data(title.utf8).base64EncodedString() + "?="
            let mail = """
            From: Sender <sender@example.test>
            To: Receiver <receiver@example.test>
            Subject: \(subject)
            Date: Sat, 17 Oct 2026 12:00:00 +0000
            Message-ID: <message\(number)@example.test>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="outer"

            --outer
            Content-Type: multipart/related; boundary="related"

            --related
            Content-Type: text/html; charset=UTF-8

            <p>DOCBODY\(number)</p><p><img src="cid:picture" alt="Picture"></p><a href="https://example.test/\(number)">LINK\(number)</a>
            --related
            Content-Type: image/png
            Content-ID: <picture>
            Content-Transfer-Encoding: base64

            \(image.base64EncodedString())
            --related--
            --outer
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename="same.bin"
            Content-Transfer-Encoding: base64

            \(Data([UInt8(number), 0, 255]).base64EncodedString())
            --outer--

            """
            entries.append(.init(name: "message\(number).eml", content: Data(mail.utf8)))
        }
        let source = root.appendingPathComponent("Archive Grüße.collectionfixture")
        try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        return (source, image)
    }
}

private struct MailCollectionFixtureAdapter: DocumentConversionAdapter {
    var failAfter: Int? = nil
    let supportedFormatDescriptors = [SupportedFormat(format: .eml, fileExtensions: ["collectionfixture"], containerKind: .file, requiredTools: [.pandoc])]
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection { .match(.init(format: .eml, priority: 999, expectedWarnings: [])) }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        try ZIPArchiveInspector.withVerifiedReader(at: context.resolvedInputURL) { reader in
            let count = Int(String(decoding: try reader.data(named: "count.txt"), as: UTF8.self))!
            var writer = CollectionOutputWriter(context: context)
            for number in 1...count {
                if number == failAfter { throw ImportFailure("controlled later-message failure") }
                let part = try MIMEMessage.read(reader.data(named: "message\(number).eml"), emlx: false)
                let metadata = try MailAdapter.metadata(part.headers)
                let table = try MailAdapter.headerTable(part.headers)
                try writer.append(title: metadata.title ?? String(number), metadata: metadata, location: .init(message: "<message\(number)@example.test>")) { child in
                    let result = try MailBodyConverter.convert(part, context: child)
                    try ConversionPostprocessor.prepend(table, to: child.stagedOutputDirectory.appendingPathComponent(result.markdownRelativePath))
                    return result
                }
            }
            return try writer.finish(metadata: .init(title: "Archive overview"))
        }
    }
}

private struct CollectionContractFixture: DocumentConversionAdapter {
    enum Mode: String { case empty, rogue, fifo, symlink, traversal, nested, metadataLimit, missingAsset, badIndex, backlink, reservedInfo }
    let mode: Mode
    let supportedFormatDescriptors = [SupportedFormat(format: .eml, fileExtensions: ["fixture"], containerKind: .file, requiredTools: [])]
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection { .match(.init(format: .eml, priority: 999, expectedWarnings: [])) }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        _ = try VerifiedFileStaging.contents(of: context.resolvedInputURL, maximumBytes: 1024, describedAs: "a collection fixture")
        var writer = CollectionOutputWriter(context: context)
        if mode != .empty {
            let metadata = DocumentMetadata(title: "Child", description: mode == .metadataLimit ? String(repeating: "x", count: 65_537) : nil)
            try writer.append(title: "Child", metadata: metadata, location: .init(note: "1")) { child in
                if mode == .traversal { return .init(markdownRelativePath: "../outside.md", assetRelativePaths: [], warnings: []) }
                let text = "BODY\n\n[Overview](../../../index.md)\n\n`[literal](../../../index.md)`\n"
                let path = try child.writeMarkdown(text)
                if mode == .nested { return .init(markdownRelativePath: path, assetRelativePaths: [], warnings: [], documents: []) }
                if mode == .symlink {
                    try FileManager.default.createSymbolicLink(at: child.stagedOutputDirectory.appendingPathComponent("image.bin"), withDestinationURL: context.resolvedInputURL)
                }
                return .init(markdownRelativePath: path, assetRelativePaths: [.symlink, .missingAsset].contains(mode) ? ["image.bin"] : [], warnings: [])
            }
        }
        let result = try writer.finish(metadata: .init(title: "Overview"))
        if mode == .rogue { try Data("UNREPORTED".utf8).write(to: context.stagedOutputDirectory.appendingPathComponent("rogue.txt")) }
        if mode == .fifo {
            guard mkfifo(context.stagedOutputDirectory.appendingPathComponent("pipe").path, 0o600) == 0 else { throw ImportFailure("could not create the owned FIFO fixture") }
        }
        if mode == .badIndex, let document = result.documents?.first {
            return .init(markdownRelativePath: result.markdownRelativePath, assetRelativePaths: result.assetRelativePaths, warnings: [], documents: [
                .init(sourceIndex: 2, title: document.title, markdownRelativePath: document.markdownRelativePath,
                    assetRelativePaths: document.assetRelativePaths, metadata: document.metadata, location: document.location)
            ])
        }
        if mode == .reservedInfo, let document = result.documents?.first {
            try Data("ORIGINAL_ASSET".utf8).write(to: context.stagedOutputDirectory.appendingPathComponent("info.json"))
            return .init(markdownRelativePath: result.markdownRelativePath, assetRelativePaths: ["info.json"], warnings: [], documents: [
                .init(sourceIndex: 1, title: document.title, markdownRelativePath: document.markdownRelativePath,
                    assetRelativePaths: ["info.json"], metadata: document.metadata, location: document.location)
            ])
        }
        return result
    }
}
