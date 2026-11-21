import Foundation
import XCTest
@testable import PoorMansTextCore

final class MIMEMessageRegressionTests: XCTestCase {
    func testNamedRelatedRootAndUndecodableResource() throws {
        for start in ["", "; start=\"<root>\""] {
            let source = """
            Content-Type: multipart/related; boundary=x\(start)

            --x
            Content-Type: text/html
            Content-ID: <root>
            Content-Disposition: inline; filename=body.html

            <p>Readable body</p>
            --x
            Content-Type: text/plain; charset=unknown
            Content-ID: <resource>

            Resource bytes
            --x--
            """
            let selection = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
            XCTAssertEqual(selection.bodies.map(\.text), ["<p>Readable body</p>"])
            XCTAssertEqual(selection.attachments.count, 1)
            XCTAssertEqual(String(decoding: selection.attachments[0].data, as: UTF8.self), "Resource bytes")
        }
    }

    func testEncryptedSMIMEBodyRejectedButForeignAttachmentPreserved() throws {
        for type in ["application/pkcs7-mime", "application/x-pkcs7-mime"] {
            let body = "Content-Type: \(type); smime-type=enveloped-data\n\nopaque"
            XCTAssertThrowsError(try MailContent.select(MIMEMessage.read(Data(body.utf8))))
            let attached = "Content-Disposition: attachment; filename=foreign.p7m\n" + body
            let selection = try MailContent.select(MIMEMessage.read(Data(attached.utf8)))
            XCTAssertEqual(selection.attachments.first?.data, Data("opaque".utf8))
        }
    }

    func testCharsetAttributesCannotBeSpoofedByDescriptions() throws {
        for decoy in ["name=\"description\" content=\"charset=windows-1251\"", "data-charset=\"windows-1251\""] {
            let html = "<meta \(decoy)><meta charset=\"iso-8859-1\"><p>Grüße café</p>"
            let data = try XCTUnwrap(html.data(using: .windowsCP1252))
            XCTAssertEqual(PandocTextAdapter.declaredCharset(in: data), "iso-8859-1")
        }
        XCTAssertEqual(PandocTextAdapter.declaredCharset(in: Data("<meta http-equiv='Content-Type' content='text/html; charset=windows-1252'>".utf8)), "windows-1252")
    }
}
