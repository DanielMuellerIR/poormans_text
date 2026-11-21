import AppKit
import XCTest
@testable import PoorMansTextCore

final class ColoredTextMarkerTests: XCTestCase {
    func testMarksChromaticTextPerLineButLeavesGrayTextAlone() {
        let text = "Plain Purple one\nPurple two\nGray"
        let document = NSMutableAttributedString(string: text)
        let purpleRange = (text as NSString).range(of: "Purple one\nPurple two")
        let grayRange = (text as NSString).range(of: "Gray")
        document.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: purpleRange)
        document.addAttribute(.foregroundColor, value: NSColor.gray, range: grayRange)

        XCTAssertEqual(ColoredTextMarker.insertMarkers(in: document), 2)
        XCTAssertEqual(
            document.string,
            "Plain ==Purple one==\n==Purple two==\nGray"
        )
    }
}
