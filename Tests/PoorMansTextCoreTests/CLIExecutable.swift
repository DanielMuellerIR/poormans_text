import Foundation
import XCTest

func cliExecutable(for testCase: XCTestCase.Type) throws -> URL {
    #if os(Linux)
    let products = try XCTUnwrap(Bundle.main.executableURL).deletingLastPathComponent()
    #else
    let products = Bundle(for: testCase).bundleURL.deletingLastPathComponent()
    #endif
    return products.appendingPathComponent("poormans-text")
}
