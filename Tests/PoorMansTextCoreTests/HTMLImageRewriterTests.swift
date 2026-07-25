import Foundation
import XCTest
@testable import PoorMansTextCore

final class HTMLImageRewriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRewritesAndCopiesRepeatedUnicodeImageOnce() throws {
        let sourceName = "an image ä.png"
        let sourceData = Data([0, 1, 2, 3])
        try sourceData.write(to: temporaryDirectory.appendingPathComponent(sourceName))
        let imagesURL = temporaryDirectory.appendingPathComponent("output/images")
        let html = #"<p><img src="file:///an%20image%20a%CC%88.png"><img src="file:///an%20image%20a%CC%88.png"></p>"#

        let result = try HTMLImageRewriter.rewrite(
            html: html,
            resourceDirectory: temporaryDirectory,
            imageDirectory: imagesURL,
            fileManager: .default
        )

        XCTAssertEqual(result.assetNames, [sourceName])
        XCTAssertEqual(result.sourceNames, [sourceName])
        XCTAssertEqual(
            result.html.components(separatedBy: "images/an%20image%20a%CC%88.png").count - 1,
            2
        )
        XCTAssertEqual(
            try Data(contentsOf: imagesURL.appendingPathComponent(sourceName)),
            sourceData
        )
    }

    func testRejectsRemoteImageReference() throws {
        let html = #"<img src="https://example.com/private.png">"#

        XCTAssertThrowsError(
            try HTMLImageRewriter.rewrite(
                html: html,
                resourceDirectory: temporaryDirectory,
                imageDirectory: temporaryDirectory.appendingPathComponent("images"),
                fileManager: .default
            )
        ) { error in
            guard case ConversionError.unsafeImageReference = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAcceptsNestedExtractedMediaButRejectsTraversalAndSymlinks() throws {
        let mediaDirectory = temporaryDirectory.appendingPathComponent("media")
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: false
        )
        let sourceData = Data([4, 5, 6])
        try sourceData.write(to: mediaDirectory.appendingPathComponent("nested.png"))

        let result = try HTMLImageRewriter.rewrite(
            html: #"<img src="media/nested.png">"#,
            resourceDirectory: temporaryDirectory,
            imageDirectory: temporaryDirectory.appendingPathComponent("output/images"),
            fileManager: .default
        )
        XCTAssertEqual(result.assetNames, ["nested.png"])

        let outsideURL = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data([7]).write(to: outsideURL)
        defer {
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let symlinkURL = temporaryDirectory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)

        for unsafeReference in ["../outside.png", "link.png"] {
            XCTAssertThrowsError(
                try HTMLImageRewriter.rewrite(
                    html: #"<img src="\#(unsafeReference)">"#,
                    resourceDirectory: temporaryDirectory,
                    imageDirectory: temporaryDirectory.appendingPathComponent("rejected/images"),
                    fileManager: .default
                )
            ) { error in
                guard case ConversionError.unsafeImageReference = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }
}
