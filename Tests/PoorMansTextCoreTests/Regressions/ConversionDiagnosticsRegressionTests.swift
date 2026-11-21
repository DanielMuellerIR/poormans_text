import Foundation
import XCTest
@testable import PoorMansTextCore

final class ConversionDiagnosticsRegressionTests: XCTestCase {
    func testPDFFailureWarningAllowsForPreservedFallbackText() {
        XCTAssertTrue(ConversionWarning.pdfOCRFailed.message.contains("fallback text"))
        XCTAssertFalse(ConversionWarning.pdfOCRFailed.message.contains("without text"))
    }
}
