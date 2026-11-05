import Foundation
#if os(Linux)
import FoundationXML
#endif
import XCTest
@testable import PoorMansTextCore

final class PortableXMLDOMTests: XCTestCase {
    func testEPUBDOMWithoutDTDPreservesNamespaceAndUnicode() throws {
        let bytes = Data("<html xmlns='http://www.w3.org/1999/xhtml'><body><p>Grüße 😀</p></body></html>".utf8)
        let document = try EPUBSelectionPackage.xml(bytes)
        XCTAssertEqual(document.rootElement()?.localName, "html")
        XCTAssertEqual(document.rootElement()?.uri, "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(document.rootElement()?.stringValue, "Grüße 😀")
    }

    func testEPUBOverviewReadsUnqualifiedAttributesInDefaultNamespaces() throws {
        // Eigenes minimales EPUB: Container, OPF mit einem Spine-Eintrag, XHTML.
        let bytes = try XCTUnwrap(Data(base64Encoded: """
        UEsDBBQAAAAAAI65ZF1vYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAACACOuWRdgZ9S
        t3oAAAC0AAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxNjUEOAiEMRa8yYWuQPQHuUpmiRGgbKMl4exNjRndv8d7/ITMpVMKx
        Hb3RjGYN8gyzTk/QcXrNngVp57w6kvqP5s/MpDCYtdSG84dbWa1ZAX1EI5CfcMcrSzFbx72C1ZdgNCDSagatTI7xJtN+1cvRm3Ep
        uL9ldz6mN1BLAwQUAAAACACOuWRdCamRJ+sAAACXAQAACwAAAHBhY2thZ2Uub3BmVZFbboQwDEW3EuW3GsK0H5VQyBq6BQ9xwJq8
        Gkyhu68IM7T9tO/RuZasMwx3GFFswce5lxNz7pRa17Uhm12Tyqhe2/Zdpeyk+MIyU4q9fGtaKZZInwteyGJkcoSll7eU7tLogAwW
        GA5rZ4dTnJfiq9QOCj0GjDyra3NV0mg7dL8uQfapyyUlp9W/uNJM7NF8pMJw8yh2umLHfic8xHGBEQ3GmpyzVs8bjQ4QyeHMRhNj
        qMXDBJmxSDEVdOfYbBMHL0VAS3Dh74y9hJw9DcCUoqrxyxa8VHvBqZ0zRTzsBZ0g+1da2QehHt8wP1BLAwQUAAAACACOuWRd2MXO
        03EAAACSAAAADQAAAGNoYXB0ZXIueGh0bWxtzbEJwzAQRuFVjAfwIVIp/Lk2bVaQ48NnkCOhHMieJouk82LBqE37+OBBbY3dtsbX
        +9arWb4S1VqHehlSmcl572k7Tc9QCRPDFovCj1QsjFG6p4ZsUkCtg5oa07Qz1P2B6hiZ7+X4Hh8BZQY1TeeHf1BLAQIUAxQAAAAA
        AI65ZF1vYassFAAAABQAAAAIAAAAAAAAAAAAAACAAQAAAABtaW1ldHlwZVBLAQIUAxQAAAAIAI65ZF2Bn1K3egAAALQAAAAWAAAA
        AAAAAAAAAACAAToAAABNRVRBLUlORi9jb250YWluZXIueG1sUEsBAhQDFAAAAAgAjrlkXQmpkSfrAAAAlwEAAAsAAAAAAAAAAAAA
        AIAB6AAAAHBhY2thZ2Uub3BmUEsBAhQDFAAAAAgAjrlkXdjFztNxAAAAkgAAAA0AAAAAAAAAAAAAAIAB/AEAAGNoYXB0ZXIueGh0
        bWxQSwUGAAAAAAQABADuAAAAmAIAAAAA
        """, options: .ignoreUnknownCharacters))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PMT-EPUB-DOM-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try bytes.write(to: source)
        let summary = try DocumentConverter().inspectEPUBContents(source)
        XCTAssertEqual(summary.chapterCount, 1)
        XCTAssertEqual(summary.chapters.map(\.number), [1])
        XCTAssertEqual(summary.chapters.map(\.title), ["Portable chapter"])
        XCTAssertEqual(summary.chapters.map(\.path), ["chapter.xhtml"])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["book.epub"])
    }

    func testEPUBDOMKeepsHarmlessDoctypeButRejectsExternalDTDAndEntities() throws {
        XCTAssertNoThrow(try EPUBSelectionPackage.xml(Data("<!DOCTYPE html><html/>".utf8)))
        for declaration in [
            "<!DOCTYPE html SYSTEM 'file:///must-not-be-read'>",
            "<!DOCTYPE html PUBLIC '-//Fixture//DTD//EN' 'https://fixture.invalid/external.dtd'>",
            "<!DOCTYPE html [<!ENTITY injected 'not allowed'>]>",
            "<!DOCTYPE html [<!ENTITY injected SYSTEM 'file:///must-not-be-read'>]>",
        ] {
            XCTAssertThrowsError(try EPUBSelectionPackage.xml(Data((declaration + "<html/>").utf8)), declaration)
        }
    }
}
