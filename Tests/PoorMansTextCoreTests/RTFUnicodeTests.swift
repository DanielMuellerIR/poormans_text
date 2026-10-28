import Foundation
import XCTest
@testable import PoorMansTextCore

final class RTFUnicodeTests: XCTestCase {
    func testTextutilDocumentPreservesEveryScalarAndSourceBytes() throws {
        try withDirectory { root in
            let expected = "Start 😀 𝄞 𠀋 Grüße 🧑🏽‍💻 Ende"
            let text = root.appendingPathComponent("source.txt")
            let source = root.appendingPathComponent("source.rtf")
            try expected.write(to: text, atomically: true, encoding: .utf8)
            let conversion = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                arguments: ["-convert", "rtf", "-output", source.path, text.path],
                currentDirectory: root
            )
            XCTAssertEqual(conversion.status, 0)
            let original = try Data(contentsOf: source)
            let result = try RichTextConverter().convert(inputURL: source)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(markdown.trimmingCharacters(in: .whitespacesAndNewlines), expected)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testSignedPairsFallbacksAndGroupScopedFallbackCounts() throws {
        try withDirectory { root in
            let rtf = #"{\rtf1\ansi\uc1 A\u-10179?\u-8704?B {\uc2\u-10188??\u-8930??C}D\u252\'3fE}"#
            XCTAssertEqual(try convert(rtf, in: root), "A😀B 𝄞CDüE")
        }
    }

    func testLiteralApostropheAfterHexEscapeRemainsText() throws {
        try withDirectory { root in
            XCTAssertEqual(try convert(#"{\rtf1\ansi \'e1'\'ba 'ab'cd \\'ef}"#, in: root), #"á'º 'ab'cd \\'ef"#)
        }
    }

    func testWordFontCharsetsAndGroupRestoration() throws {
        try withDirectory { root in
            let rtf = #"{\rtf1\ansi\ansicpg1252\deff1{\fonttbl{\f0\fcharset0 Arial;}{\f1\fcharset204 Arial Cyr;}}\'cf\'f0\'e8\'e2\'b3\'f2 {\f0 Gr\'fc\'dfe} \'ee\'e1'\'ba\'ea\'f2\plain !}"#
            XCTAssertEqual(try convert(rtf, in: root), "Привіт Grüße об'єкт!")
        }
    }

    func testHeaderAndExplicitFontCodepagesAndMultibyteRuns() throws {
        for (header, text, expected) in [
            (#"\ansicpg1251"#, #"\'cf\'f0\'e8\'e2\'b3\'f2"#, "Привіт"),
            (#"\ansicpg1252{\fonttbl{\f0\cpg1251\fcharset0 Arial;}}\f0"#, #"\'cf\'f0\'e8\'e2\'b3\'f2"#, "Привіт"),
            (#"\ansicpg1252{\fonttbl{\f0\fcharset128 MS Gothic;}}\f0"#, #"\'93\'fa\'96\'7b\'8c\'ea"#, "日本語")
        ] {
            try withDirectory { root in
                XCTAssertEqual(try convert("{\\rtf1\\ansi" + header + " " + text + "}", in: root), expected)
            }
        }
    }

    func testWordEncodedTextAndEmbeddedPictureBothSurvive() throws {
        try withDirectory { root in
            let fixture = try FixtureFactory.createRichRTF(in: root)
            var rtf = try String(contentsOf: fixture.fileURL, encoding: .utf8)
            rtf = rtf.replacingOccurrences(of: "Start ", with: #"{\ansicpg1251 \'ee\'e1'\'ba\'ea\'f2} Start "#)
            try rtf.write(to: fixture.fileURL, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: fixture.fileURL)
            let result = try RichTextConverter().convert(inputURL: fixture.fileURL)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(markdown.contains("об'єкт Start **bold**"), markdown)
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), fixture.imageData)
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        }
    }

    func testPairAcrossFormattingGroupsPreservesTheCharacter() throws {
        try withDirectory { root in
            XCTAssertEqual(try convert(#"{\rtf1\ansi\uc0 A{\b\u55357}\u56832 B}"#, in: root), "A**😀**B")
        }
    }

    func testUnicodeAndEmbeddedPictureBothSurvive() throws {
        try withDirectory { root in
            let fixture = try FixtureFactory.createRichRTF(in: root)
            var rtf = try String(contentsOf: fixture.fileURL, encoding: .utf8)
            rtf = rtf.replacingOccurrences(of: "Start ", with: #"Start \uc0\u55357\u56832 "#)
            try rtf.write(to: fixture.fileURL, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: fixture.fileURL)
            let result = try RichTextConverter().convert(inputURL: fixture.fileURL)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(markdown.contains("Start 😀"), markdown)
            XCTAssertTrue(markdown.contains("**bold**"), markdown)
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), fixture.imageData)
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        }
    }

    func testMalformedUnicodeFailsWithoutPublishingAnOutput() throws {
        for rtf in [#"{\rtf1\uc0\u55357}"#, #"{\rtf1\uc0\u56832}"#,
                    #"{\rtf1\uc0\u55357 X\u56832}"#, #"{\rtf1\u65536?}"#] {
            try withDirectory { root in
                let source = root.appendingPathComponent("broken.rtf")
                try Data(rtf.utf8).write(to: source)
                XCTAssertThrowsError(try RichTextConverter().convert(inputURL: source)) { error in
                    guard case ConversionError.invalidRichText(_, let reason) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertTrue(reason.contains("Unicode"), reason)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("broken-markdown").path))
                XCTAssertEqual(try Data(contentsOf: source), Data(rtf.utf8))
            }
        }
    }

    func testEscapedControlsAndBinaryPayloadRemainByteIdentical() throws {
        let source = Data(#"{\rtf1 literal \\u55357 {\pict\bin16 \u55357\u56832!' }}"#.utf8)
        XCTAssertEqual(try RTFUnicodeProtector.protect(source).data, source)
    }

    func testUndecodableTextFailsWithoutPublishingAnOutput() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("broken.rtf")
            let data = Data(#"{\rtf1\ansi\ansicpg932 \'93}"#.utf8)
            try data.write(to: source)
            XCTAssertThrowsError(try RichTextConverter().convert(inputURL: source)) { error in
                guard case ConversionError.invalidRichText(_, let reason) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(reason.contains("code page 932"), reason)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("broken-markdown").path))
            XCTAssertEqual(try Data(contentsOf: source), data)
        }
    }

    func testUnicodeFallbackIsNotDecodedAsFontText() throws {
        try withDirectory { root in
            XCTAssertEqual(try convert(#"{\rtf1\ansi\ansicpg932\uc1\u252\'93\u223'\'93\'fa}"#, in: root), "üß日")
        }
    }

    func testEscapedShiftJISTrailBytesMatchHexEncoding() throws {
        for (literal, hex, expected) in [(#"\\"#, "5c", "表"), (#"\{"#, "7b", "府"), (#"\}"#, "7d", "扶")] {
            for tail in [literal, "\\'" + hex] {
                try withDirectory { root in
                    let rtf = "{\\rtf1\\ansi\\ansicpg932 \\'95" + tail + "}"
                    let source = root.appendingPathComponent("source.rtf")
                    let data = Data(rtf.utf8)
                    XCTAssertEqual(try convert(rtf, in: root), expected)
                    XCTAssertEqual(try Data(contentsOf: source), data)
                    let reference = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                        arguments: ["-convert", "txt", "-stdout", source.path], currentDirectory: root, captureStandardOutput: true)
                    XCTAssertEqual(reference.status, 0)
                    XCTAssertEqual(reference.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), expected)
                }
            }
        }
    }

    func testHTMLCharactersAreRestoredAsTextAndUnicodeLinkRemainsSafe() throws {
        try withDirectory { root in
            let rtf = #"{\rtf1\ansi\uc0 A\u60 img\u62 \u38 B {\field{\*\fldinst HYPERLINK "https://example.com/\u55357\u56832"}{\fldrslt \u55357\u56832}}}"#
            let markdown = try convert(rtf, in: root)
            XCTAssertTrue(markdown.contains("&lt;img&gt;" ) || markdown.contains("\\<img\\>"), markdown)
            XCTAssertTrue(markdown.contains("😀"), markdown)
            XCTAssertTrue(markdown.contains("https://example.com/"), markdown)
            XCTAssertFalse(markdown.contains("POORMANSTEXTUNICODE"), markdown)
        }
    }

    private func convert(_ rtf: String, in root: URL) throws -> String {
        let source = root.appendingPathComponent("source.rtf")
        try Data(rtf.utf8).write(to: source)
        let result = try RichTextConverter().convert(inputURL: source)
        return try String(contentsOf: result.markdownFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pandoc")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/pandoc") else {
            throw XCTSkip("Pandoc is not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RTFUnicode-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
