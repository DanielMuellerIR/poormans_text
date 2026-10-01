import Foundation
import XCTest
@testable import PoorMansTextCore

final class MIMEMessageTests: XCTestCase {
    func testNestedAlternativeAndBinaryAttachment() throws {
        let source = """
        From: sender@example.invalid
        Subject: Test
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Gr=C3=BC=C3=9Fe=\nweiter
        --inner
        Content-Type: text/html; charset=utf-8

        <p>Grüße</p>
        --inner--
        --outer
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*=utf-8''..%2Fsecret.bin
        Content-Transfer-Encoding: base64

        AAEC/w==
        --outer--
        """
        let mail = try MIMEMessage.read(Data(source.utf8))
        XCTAssertEqual(mail.children.count, 2)
        XCTAssertEqual(mail.children[0].children.count, 2)
        XCTAssertEqual(try mail.children[0].children[0].text(), "Grüßeweiter")
        XCTAssertEqual(mail.children[1].body, Data([0, 1, 2, 255]))
        XCTAssertEqual(mail.children[1].filename, "../secret.bin")
    }

    func testAppleMailCountUsesBytesAndExcludesTrailingPlist() throws {
        let message = Data("Subject: Grüße\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nKörper".utf8)
        var emlx = Data("\(message.count)\n".utf8)
        emlx.append(message)
        emlx.append(Data("\n<?xml version=\"1.0\"?><plist/>".utf8))
        let mail = try MIMEMessage.read(emlx, emlx: true)
        XCTAssertEqual(try mail.text(), "Körper")
        XCTAssertEqual(mail.header("subject"), "Grüße")
        XCTAssertThrowsError(try MIMEMessage.read(Data("999999\nSubject: bad\n\nbody".utf8), emlx: true))
    }

    func testFoldedHeadersAndCharset() throws {
        let mail = try MIMEMessage.read(Data("Subject: first\r\n second\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nGr=FC=DFe".utf8))
        XCTAssertEqual(mail.header("subject"), "first second")
        XCTAssertEqual(try mail.text(), "Grüße")
    }

    func testEncodedHeadersJoinOnlyWhitespaceBetweenEncodedWords() throws {
        XCTAssertEqual(try MIMEMessage.decodedHeader("=?utf-8?Q?Gr=C3=BC?= \t=?utf-8?B?w59l?="), "Grüße")
        XCTAssertEqual(try MIMEMessage.decodedHeader("Name =?iso-8859-1?Q?M=FCller?= <a@example.invalid>"), "Name Müller <a@example.invalid>")
        XCTAssertThrowsError(try MIMEMessage.decodedHeader("=?unknown-charset?Q?abc?="))
    }

    func testMalformedMailIsRejected() {
        for source in [
            "Subject: no separator",
            " orphan\n\nbody",
            "Content-Type: text/plain\nContent-Type: text/html\n\nbody",
            "Content-Type: multipart/mixed; boundary=x\n\n--x\n\nbody",
            "Content-Transfer-Encoding: base64\n\n!!!",
            "Content-Transfer-Encoding: quoted-printable\n\n=ZZ",
            "Content-Transfer-Encoding: unsupported\n\nbody",
            "Content-Type: text/plain; charset=\"unfinished\n\nbody",
            "Content-Type: text/plain; name*1*=utf-8''missing\n\nbody",
        ] {
            XCTAssertThrowsError(try MIMEMessage.read(Data(source.utf8)), source)
        }
    }

    func testBoundaryMustOccupyAnEntireLine() throws {
        let source = "Content-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: text/plain\n\nkeep --x and\n--x-extra\n--x--"
        let mail = try MIMEMessage.read(Data(source.utf8))
        XCTAssertEqual(try mail.children[0].text(), "keep --x and\n--x-extra")
    }

    func testParameterContinuationAndQuotedSemicolon() throws {
        let value = try MIMEMessage.parameterized("attachment; filename*0*=utf-8''Gr%C3; filename*1*=%BC%C3%9Fe.txt")
        XCTAssertEqual(value.1["filename"], "Grüße.txt")
        XCTAssertEqual(try MIMEMessage.parameterized("attachment; filename=\"a;b.txt\"").1["filename"], "a;b.txt")
        XCTAssertEqual(try MIMEMessage.parameterized("attachment; filename*0*=utf-8''file; filename*1=%20.txt").1["filename"], "file%20.txt")
        XCTAssertThrowsError(try MIMEMessage.parameterized("attachment; filename*=utf-8''first; filename*0*=utf-8''second"))
    }

    func testNestingBudgetRejectsSmallDeepMail() {
        var source = "Content-Type: text/plain\n\ntext"
        for index in 0...MIMEMessage.maximumDepth {
            source = "Content-Type: multipart/mixed; boundary=b\(index)\n\n--b\(index)\n\(source)\n--b\(index)--"
        }
        XCTAssertThrowsError(try MIMEMessage.read(Data(source.utf8)))
    }

    func testEmptyMultipartBodyKeepsItsHeaderSeparator() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["Content-Type: multipart/mixed; boundary=x", "", "--x", "Content-Type: text/plain", "", "--x--"].joined(separator: newline)
            let mail = try MIMEMessage.read(Data(source.utf8))
            XCTAssertEqual(mail.children.count, 1)
            XCTAssertTrue(mail.children[0].body.isEmpty)
        }
    }
}
