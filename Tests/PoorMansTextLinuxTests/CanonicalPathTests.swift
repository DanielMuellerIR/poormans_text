#if os(Linux)
import Foundation
import XCTest
@testable import PoorMansTextCore

final class CanonicalPathTests: XCTestCase {
    private let composed = "é"
    private let decomposed = "e\u{0301}"
    private let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAIAAADkharWAAAAGElEQVR4nGP8z0AaYCJRPcOoBmLAcAglAGavARduQJjLAAAAAElFTkSuQmCC")!
    private let blue = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAIAAADkharWAAAAGklEQVR4nGNkYPjPQApgIkk1w6gG4sBwCFYAZLEBF7/CHPgAAAAASUVORK5CYII=")!
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCanonical-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func directory(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testFolderAndBatchRetainBothPhysicalNamesAndSourceFingerprints() throws {
        try withRoot { root in
            let first = root.appendingPathComponent(composed + ".csv")
            let second = root.appendingPathComponent(decomposed + ".csv")
            let originals = [Data("Key,Value\nNFCTOKEN,1\n".utf8), Data("Key,Value\nNFDTOKEN,2\n".utf8)]
            try originals[0].write(to: first); try originals[1].write(to: second)
            let inputs = try InputEnumerator().enumerate([root])
            XCTAssertEqual(inputs.count, 2)
            XCTAssertEqual(Set(inputs.map { FileSystemPath.key($0.url.path) }).count, 2)
            let results = try BatchConverter().convert(inputs.map { .init(inputURL: $0.url, options: .init(conversionReport: true)) }, jobs: 2)
            XCTAssertEqual(results.count, 2)
            var texts = [String](), outputs = Set<String>()
            for result in results {
                let converted = try result.outcome.get()
                texts.append(try String(contentsOf: converted.markdownFile, encoding: .utf8))
                outputs.insert(FileSystemPath.key(converted.outputDirectory.path))
                let original = try Data(contentsOf: result.inputURL)
                XCTAssertEqual(converted.sourceIdentity?.sha256, ConversionFileFingerprint.digest(original))
            }
            XCTAssertEqual(outputs.count, 2)
            XCTAssertEqual(texts.filter { $0.contains("NFCTOKEN") }.count, 1)
            XCTAssertEqual(texts.filter { $0.contains("NFDTOKEN") }.count, 1)
            XCTAssertEqual(try Data(contentsOf: first), originals[0]); XCTAssertEqual(try Data(contentsOf: second), originals[1])
        }
    }
    func testBatchReservesDistinctCaseSensitiveOutputNames() throws {
        try withRoot { root in
            let sources = try directory(root, "sources"), outputs = try directory(root, "outputs")
            let requests = try ["A", "a"].map { name -> ConversionRequest in
                let source = sources.appendingPathComponent(name + ".csv")
                try Data("Key,Value\n\(name),1\n".utf8).write(to: source)
                return .init(inputURL: source, destination: .directory(outputs.appendingPathComponent(name + "-markdown")))
            }
            let results = try BatchConverter().convert(requests, jobs: 2, outputRoots: [outputs], protecting: [sources])
            XCTAssertEqual(results.count, 2)
            for result in results {
                let output = try result.outcome.get()
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.markdownFile.path))
                XCTAssertEqual(try Data(contentsOf: result.inputURL), Data("Key,Value\n\(result.inputURL.deletingPathExtension().lastPathComponent),1\n".utf8))
            }
            XCTAssertEqual(Set(results.compactMap { try? $0.outcome.get().outputDirectory.path }).count, 2)
        }
    }
    func testHTMLCannotReadCanonicallyEquivalentSiblingThroughTraversalOrSymlink() throws {
        try withRoot { root in
            let inside = try directory(root, composed), outside = try directory(root, decomposed)
            let work = try directory(root, "work")
            try red.write(to: outside.appendingPathComponent("pixel.png"))
            try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("pixel.png"))
            let html = "<img src=\"../\(decomposed)/pixel.png\" alt=\"TRAVERSAL\"><img src=\"link.png\" alt=\"LINK\">"
            let resolved = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: inside, baseURL: nil, subresources: [:], workDirectory: work)
            XCTAssertEqual(resolved.missingImagesDropped, 2)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("pixel.png")), red)
        }
    }
    func testHTMLLocalResourceCachesKeepBothImages() throws {
        try withRoot { root in
            let source = try directory(root, "source"), work = try directory(root, "work")
            try red.write(to: source.appendingPathComponent(composed + ".png"))
            try blue.write(to: source.appendingPathComponent(decomposed + ".png"))
            let html = "<img src=\"\(composed).png\"><img src=\"\(decomposed).png\">"
            let resolved = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: source, baseURL: nil, subresources: [:], workDirectory: work)
            XCTAssertEqual(resolved.missingImagesDropped, 0)
            let files = try FileManager.default.contentsOfDirectory(at: work.appendingPathComponent("external"), includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 2)
            XCTAssertEqual(try Set(files.map { try Data(contentsOf: $0) }), Set([red, blue]))
            let images = root.appendingPathComponent("images")
            let rewritten = try HTMLImageRewriter.rewrite(html: html, resourceDirectory: source, imageDirectory: images, fileManager: .default)
            XCTAssertEqual(rewritten.assetNames.count, 2)
            XCTAssertEqual(rewritten.sourceNames.count, 2)
            XCTAssertEqual(try Set(rewritten.assetNames.map { try Data(contentsOf: images.appendingPathComponent($0)) }), Set([red, blue]))
        }
    }
    func testWebArchiveRetainsBothUnicodeResourceAddresses() throws {
        try withRoot { root in
            let names = [composed + ".png", decomposed + ".png"]
            let images = [red, blue]
            let html = names.map { "<img src=\"file:///saved/\($0)\">" }.joined()
            let resources = zip(names, images).map { name, data in
                ["WebResourceURL": "file:///saved/" + name, "WebResourceMIMEType": "image/png", "WebResourceData": data] as [String: Any]
            }
            let plist: [String: Any] = ["WebMainResource": ["WebResourceURL": "file:///saved/page.html", "WebResourceMIMEType": "text/html", "WebResourceData": Data(html.utf8)], "WebSubresources": resources]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let archive = try WebArchiveReader.read(data)
            XCTAssertEqual(archive.subresources.count, 2)
            let result = try HTMLImageSourceResolver.resolve(html: archive.html, baseDirectory: nil, baseURL: archive.baseURL, subresources: archive.subresources, workDirectory: root)
            XCTAssertEqual(result.missingImagesDropped, 0)
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("external"), includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 2)
            XCTAssertEqual(try Set(files.map { try Data(contentsOf: $0) }), Set(images))
        }
    }
    func testNotebookRejectsCollidingAttachmentKeysBeforeFoundationDropsOne() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("pair.ipynb")
            let attachment = red.base64EncodedString()
            let original = Data("""
            {"nbformat":4,"cells":[{"cell_type":"markdown","source":"![one](attachment:é.png)","attachments":{"é.png":{"image/png":"\(attachment)"},"e\\u0301.png":{"image/png":"\(attachment)"}}}]}
            """.utf8)
            try original.write(to: source)
            let target = root.appendingPathComponent("output")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(target)))) { error in
                XCTAssertTrue(error.localizedDescription.contains("duplicate"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: source), original)
            for name in [composed, decomposed] {
                let single = Data("""
                {"nbformat":4,"cells":[{"cell_type":"markdown","source":"![one](attachment:\(name).png)","attachments":{"\(name).png":{"image/png":"\(attachment)"}}}]}
                """.utf8)
                try single.write(to: source)
                let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(target)))
                XCTAssertEqual(result.assets.count, 1)
                XCTAssertEqual(try Data(contentsOf: result.assets[0]), red)
                try FileManager.default.removeItem(at: target)
            }
        }
    }
    func testHTMLGeneratedResourceBoundaryRejectsSiblingDirectory() throws {
        try withRoot { root in
            let inside = try directory(root, composed), outside = try directory(root, decomposed)
            try red.write(to: outside.appendingPathComponent("pixel.png"))
            let html = "<img src=\"\(outside.appendingPathComponent("pixel.png").absoluteString)\">"
            XCTAssertThrowsError(try HTMLImageRewriter.rewrite(html: html, resourceDirectory: inside, imageDirectory: root.appendingPathComponent("images"), fileManager: .default))
        }
    }
    func testRTFDValidatesBothNamesAndKeepsBothValidAttachments() throws {
        try withRoot { root in
            let package = try directory(root, "source.rtfd")
            let rtf = Data(("{\\rtf1\\ansi\\ansicpg65001 {\\NeXTGraphic \(composed).png} {\\NeXTGraphic \(decomposed).png}}").utf8)
            try rtf.write(to: package.appendingPathComponent("TXT.rtf"))
            try red.write(to: package.appendingPathComponent(composed + ".png"))
            try Data("INVALID PNG".utf8).write(to: package.appendingPathComponent(decomposed + ".png"))
            XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: package))
            try blue.write(to: package.appendingPathComponent(decomposed + ".png"))
            let prepared = try LinuxRTFDPreparation.prepare(package: package)
            XCTAssertEqual(prepared.representedNames.count, 2)
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("TXT.rtf")), rtf)
        }
    }
    func testRecordingDoesNotCaptureAByteDifferentSource() throws {
        try withRoot { root in
            let recording = ConversionRecording()
            let first = root.appendingPathComponent(composed + ".csv"), second = root.appendingPathComponent(decomposed + ".csv")
            recording.activate(at: first)
            XCTAssertTrue(recording.captures(first)); XCTAssertFalse(recording.captures(second))
        }
    }
    func testSourceProtectionAllowsPhysicalSiblingButRejectsActualDescendant() throws {
        try withRoot { root in
            let first = try directory(root, composed), second = try directory(root, decomposed)
            XCTAssertNoThrow(try BatchSourceProtection.validate([second.appendingPathComponent("result")], sources: [first]))
            XCTAssertThrowsError(try BatchSourceProtection.validate([first.appendingPathComponent("result")], sources: [first]))
        }
    }
    func testProcessWritableScopeCannotBeReplacedByCanonicalSibling() throws {
        try withRoot { root in
            let first = try directory(root, composed), second = try directory(root, decomposed)
            XCTAssertThrowsError(try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/true"), arguments: [], currentDirectory: second, writeScope: first))
        }
    }
}
#endif
