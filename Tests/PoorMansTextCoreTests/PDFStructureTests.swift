import Foundation
import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class PDFStructureTests: XCTestCase {
    private func fixture(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 12, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            context.textPosition = CGPoint(x:x,y:y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:value, attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])), context)
        }
        text("Measured heading", x:40,y:730,size:20,bold:true)
        text("Body prose remains intact below the heading.",x:40,y:700)
        for y: CGFloat in [650,625,600,575] { context.move(to:CGPoint(x:40,y:y));context.addLine(to:CGPoint(x:500,y:y)) }
        for x: CGFloat in [40,250,500] { context.move(to:CGPoint(x:x,y:575));context.addLine(to:CGPoint(x:x,y:650)) }
        context.strokePath()
        text("Item",x:50,y:633,bold:true); text("Count",x:260,y:633,bold:true)
        text("Alpha | <script>",x:50,y:608);text("3",x:260,y:608)
        text("Beta",x:50,y:583);text("4",x:260,y:583)
        context.endPDFPage();context.closePDF()
    }

    func testRealPDFHeadingGridAndSourcePreservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("structure.pdf")
        try fixture(at:source)
        let bytes=try Data(contentsOf:source)
        let result=try DocumentConverter().convert(ConversionRequest(inputURL:source,destination:.directory(root.appendingPathComponent("out")),options:ConversionOptions(pdfTextRecognition:.disabled)))
        let markdown=try String(contentsOf:result.markdownFile,encoding:.utf8)
        XCTAssertTrue(markdown.contains("### Measured heading"),markdown)
        XCTAssertTrue(markdown.contains("| Item | Count |"),markdown)
        XCTAssertTrue(markdown.contains("| Alpha \\| \\<script\\> | 3 |"),markdown)
        XCTAssertTrue(markdown.contains("| Beta | 4 |"),markdown)
        for word in ["Measured heading","Body prose remains intact below the heading.","Alpha","Beta"] {
            XCTAssertEqual(markdown.components(separatedBy:word).count,2,markdown)
        }
        XCTAssertEqual(try Data(contentsOf:source),bytes)
    }

    func testIdenticalGeometryDoesNotInventColumns() {
        let box=CGRect(x:0,y:0,width:600,height:800)
        let lines=(0..<3).flatMap { i in
            [PDFTextLine(text:"Item \(i)",bounds:CGRect(x:40,y:700-i*20,width:100,height:12)),
             PDFTextLine(text:"\(i)",bounds:CGRect(x:340,y:700-i*20,width:30,height:12))]
        }
        XCTAssertTrue(PDFTextLayout.hasAmbiguousColumns(lines,pageBounds:box))
        let prose = [
            PDFTextLine(text:"A sentence continues",bounds:CGRect(x:40,y:700,width:200,height:12)),
            PDFTextLine(text:"on the following line.",bounds:CGRect(x:40,y:680,width:180,height:12)),
            PDFTextLine(text:"Another sentence continues",bounds:CGRect(x:340,y:700,width:200,height:12)),
            PDFTextLine(text:"on the right hand side.",bounds:CGRect(x:340,y:680,width:180,height:12))]
        XCTAssertFalse(PDFTextLayout.hasAmbiguousColumns(prose,pageBounds:box))
    }

    func testRealShiftedColumnGutterPreservesParagraphOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("columns.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 600)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        func draw(_ value: String, _ x: CGFloat, _ y: CGFloat) {
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
        }
        draw("The paragraph reaches past centre", 40, 520)
        draw("and continues on the left.", 40, 500)
        draw("Left conclusion stays here.", 40, 480)
        draw("Right opening has a continuation", 240, 519)
        draw("and remains on the right.", 240, 499)
        draw("Right conclusion stays here.", 240, 479)
        context.endPDFPage()
        context.closePDF()
        let bytes = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
            destination: .directory(root.appendingPathComponent("out")),
            options: ConversionOptions(pdfTextRecognition: .disabled)))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertFalse(result.diagnostics.contains { $0.code == "pdf.layoutAmbiguous" })
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of: "Left conclusion")).lowerBound,
                          try XCTUnwrap(markdown.range(of: "Right opening")).lowerBound)
        for sentence in ["The paragraph reaches past centre", "and continues on the left.",
                         "Left conclusion stays here.", "Right opening has a continuation",
                         "and remains on the right.", "Right conclusion stays here."] {
            XCTAssertEqual(markdown.components(separatedBy: sentence).count, 2, markdown)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testApprovedRealMatrixWhenProvided() throws {
        guard let directory=ProcessInfo.processInfo.environment["POORMANS_PDF_REAL_MATRIX"] else { throw XCTSkip("No approved real PDF matrix configured") }
        let root=URL(fileURLWithPath:directory)
        let cases=[(1,5),(1,30),(1,33),(3,20),(5,6),(11,6)]
        var report=[[String:Any]]()
        for (fixture,index) in cases {
            let source=root.appendingPathComponent("real-\(fixture).pdf")
            let document=try XCTUnwrap(PDFDocument(url:source))
            let page=try XCTUnwrap(document.page(at:index-1))
            let lines=try PDFTextLayout.lines(on:page)
            try (page.string ?? "").write(to:root.appendingPathComponent("page-\(fixture)-\(index).source.txt"),atomically:true,encoding:.utf8)
            let body=PDFStructuredLayout.bodyFont(in:[lines])
            let sizes=Set(lines.compactMap { l in (l.fontSize ?? 0) > (body ?? 0) ? l.fontSize : nil }).sorted(by:>)
            let rendered=PDFStructuredLayout.render(lines,page:page,bodyFont:body,headingSizes:sizes,hardHyphens:false)
            try rendered.markdown.write(to:root.appendingPathComponent("page-\(fixture)-\(index).md"),atomically:true,encoding:.utf8)
            if fixture == 1 && index == 5 {
                XCTAssertTrue(rendered.markdown.contains("### About this manual"))
                XCTAssertTrue(rendered.markdown.contains("Yoga Slim 7 14IIL05 D | 82A1"))
            }
            if fixture == 1 && index == 30 {
                XCTAssertTrue(rendered.markdown.contains("| 13 | System board |"))
                XCTAssertTrue(rendered.markdown.contains("| 1 | LCD module |"))
            }
            if fixture == 1 && index == 33 {
                XCTAssertTrue(rendered.markdown.contains("| Tweezers \\(isolated\\) |  |"))
                XCTAssertTrue(rendered.markdown.contains("| Acetate tape | X |"))
            }
            if fixture == 3 && index == 20 { XCTAssertTrue(rendered.markdown.contains("What Is TextWrangler?")) }
            if fixture == 5 && index == 6 {
                XCTAssertFalse(rendered.ambiguous)
                XCTAssertLessThan(try XCTUnwrap(rendered.markdown.range(of:"Notes about discs")).lowerBound,
                                  try XCTUnwrap(rendered.markdown.range(of:"Cleaning discs")).lowerBound)
            }
            if fixture == 11 && index == 6 {
                XCTAssertFalse(rendered.ambiguous)
                XCTAssertLessThan(try XCTUnwrap(rendered.markdown.range(of:"Zu Ihrer Sicherheit")).lowerBound,
                                  try XCTUnwrap(rendered.markdown.range(of:"Strom führende Teile")).lowerBound)
            }
            report.append(["fixture":fixture,"page":index,"bodyFont":body ?? 0,"headingSizes":sizes,"lines":lines.count,"ambiguous":rendered.ambiguous,"grids":PDFTableGeometry.grids(on:page,textHeight:10).count])
        }
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("structure-report.json"))
    }
}
