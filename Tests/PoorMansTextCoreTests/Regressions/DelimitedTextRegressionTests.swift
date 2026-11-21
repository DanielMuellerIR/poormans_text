import Foundation
import XCTest
@testable import PoorMansTextCore

final class DelimitedTextRegressionTests: XCTestCase {
    func testUTF16WithHalfACharacterIsRejectedInFullConversionButToleratedWhenTruncated() throws {
        let root = try makeRegressionDirectory()
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
        let root = try makeRegressionDirectory()
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
}
