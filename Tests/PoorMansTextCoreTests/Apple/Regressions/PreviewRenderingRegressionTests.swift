import Foundation
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class PreviewRenderingRegressionTests: XCTestCase {
    func testManyInlineBreaksAndGeneratedAnchorsPreserveContent() {
        for count in [1_000, 2_000, 4_000] {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = RenderedMarkdownPreview.render(String(repeating: "x<br>", count: count), assets: nil)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            print("PMT_INLINE_BENCHMARK \(count) \(seconds)")
            XCTAssertEqual(result.html.components(separatedBy: "<br>").count - 1, count)
            XCTAssertFalse(result.limited)
        }
        let source = (1...1_000).map { "x<a id=\"pmt-epub-chapter-1-anchor-\($0)\"></a>" }.joined()
        let result = RenderedMarkdownPreview.render(source, assets: nil)
        XCTAssertEqual(result.html.components(separatedBy: "<span id=\"pmt-epub-chapter-1-anchor-").count - 1, 1_000)
        XCTAssertFalse(result.html.contains("&lt;/a&gt;")); XCTAssertFalse(result.limited)
    }
}
