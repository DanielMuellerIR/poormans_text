import Foundation
import XCTest
@testable import PoorMansTextCore

final class FictionBookConversionRegressionTests: XCTestCase {
    func testPrefixedFictionBookRootConvertsWithoutSourceChanges() throws {
        let root = try makeRegressionDirectory()
        let xml = #"<fb:FictionBook xmlns:fb="http://www.gribuser.ru/xml/fictionbook/2.0"><fb:description><fb:title-info><fb:book-title>Prefix title</fb:book-title></fb:title-info></fb:description><fb:body><fb:section><fb:p>PREFIXTOKEN</fb:p></fb:section></fb:body></fb:FictionBook>"#
        let bytes = Data(xml.utf8)
        let source = root.appendingPathComponent("prefix.fb2")
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("PREFIXTOKEN"))
        XCTAssertEqual(result.metadata.title, "Prefix title")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let fake = root.appendingPathComponent("fake.fb2")
        try Data(#"<!-- <FictionBook> --><wrong/>"#.utf8).write(to: fake)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: fake))
    }
}
