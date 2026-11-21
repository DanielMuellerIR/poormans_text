import Foundation
import AppKit
import CoreText
import PDFKit
import Markdown
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class PDFAnnotationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTPDFAnnotations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func links(_ text: String) -> [String] {
        var targets: [String] = []
        func visit(_ node: any Markup) {
            if let link = node as? Link, let destination = link.destination { targets.append(destination) }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: text)); return targets
    }
    private func decoded(_ text: String) -> String {
        var output = ""
        func visit(_ node: any Markup) {
            if let text = node as? Markdown.Text { output += text.string + "\n" }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: text)); return output
    }
    func testRealPDFCommentsHighlightsLinksDatesAndMappings() throws {
        let source = try PDFAnnotationFixture.make(in: root)
        let original = try Data(contentsOf: source)
        var receipts: [[String: Any]] = []
        for layout in [PDFLayout.automatic, .legacy] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(layout.rawValue)), options: .init(pdfTextRecognition: .disabled, pdfLayout: layout, conversionReport: true)))
            let data = try Data(contentsOf: result.markdownFile), text = String(decoding: data, as: UTF8.self)
            let body = text.components(separatedBy: "### Annotations")[0].replacingOccurrences(of: "\\_", with: "_")
            for token in PDFAnnotationFixture.bodyTokens { XCTAssertEqual(body.components(separatedBy: token).count - 1, 1, text) }
            XCTAssertEqual(links(text), [PDFAnnotationFixture.encodedWeb, "#pmt-pdf-page-2"], text)
            let plain = decoded(text)
            for token in ["COMMENT_BODY", "UNSUPPORTED_BODY", "Reviewer <script>[x]", "Highlighter", "D:20261016090000+02'00'"] { XCTAssertTrue(plain.contains(token), plain) }
            XCTAssertEqual(plain.components(separatedBy: "COMMENT_BODY").count - 1, 1)
            XCTAssertTrue(text.contains("id=\"pmt-pdf-page-1\"")); XCTAssertTrue(text.contains("id=\"pmt-pdf-page-2\""))
            XCTAssertFalse(text.contains("<script>")); XCTAssertFalse(links(text).contains { $0.contains("invalid.test") || $0.hasPrefix("javascript:") })
            XCTAssertEqual(result.diagnostics.filter { $0.code == "pdf.annotationTypeNotRepresented" }.count, 1)
            XCTAssertFalse(result.diagnostics.contains { $0.code == "pdf.linkTextUnavailable" }, "\(result.diagnostics)")
            XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.linkPreserved" && $0.location == .init(page: 1, note: "Annotation 1") })
            XCTAssertTrue(result.sourceMappings.contains { $0.source == .init(page: 1, note: "Annotation 4") && $0.output.text(in: data)?.contains("COMMENT") == true })
            for mapping in result.sourceMappings { XCTAssertNotNil(mapping.output.text(in: data)) }
            XCTAssertEqual(try Data(contentsOf: source), original)
            receipts.append(["layout": layout.rawValue, "links": links(text), "sourceSHA256": ConversionFileFingerprint.digest(original), "mappings": result.sourceMappings.count])
            if let path = ProcessInfo.processInfo.environment["PMT_PDF_ANNOTATION_DIR"] {
                let export = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: result.outputDirectory, to: export.appendingPathComponent(layout.rawValue))
            }
        }
        if let path = ProcessInfo.processInfo.environment["PMT_PDF_ANNOTATION_DIR"] {
            let export = URL(fileURLWithPath: path)
            try original.write(to: export.appendingPathComponent("review.pdf"))
            try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted,.sortedKeys]).write(to: export.appendingPathComponent("matrix.json"))
        }
    }
    func testExcludedDestinationsKeepTextWithoutDeadLinks() throws {
        let source = try PDFAnnotationFixture.make(in: root)
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("selected.textbundle")), options: .init(frontmatter: true, outputLayout: .textbundle, pdfTextRecognition: .disabled, pdfPages: IndexSelection("1"), conversionReport: true)))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(links(text), [PDFAnnotationFixture.encodedWeb])
        XCTAssertFalse(text.contains("id=\"pmt-pdf-page-2\"")); XCTAssertFalse(text.contains("BODY_TWO"))
        XCTAssertTrue(decoded(text).contains("INTERNAL_LINK_LABEL")); XCTAssertTrue(decoded(text).contains("Target page (source): 2"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.linkExcluded" && $0.location?.page == 1 })
        for mapping in result.sourceMappings { XCTAssertEqual(mapping.output.file, "text.md"); XCTAssertNotNil(mapping.output.text(in: try Data(contentsOf: result.markdownFile))) }
    }
    func testRotatedPagesRetainExactTextAndAnnotationReferences() throws {
        for rotation in [90,180,270] {
            let folder = root.appendingPathComponent(String(rotation)); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let source = try PDFAnnotationFixture.make(in: folder, rotation: rotation)
            let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(pdfTextRecognition: .disabled)))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(links(text), [PDFAnnotationFixture.encodedWeb, "#pmt-pdf-page-2"], text)
            XCTAssertTrue(decoded(text).contains("HIGHLIGHT_ONE\nHIGHLIGHT_TWO"), decoded(text))
            XCTAssertFalse(result.diagnostics.contains { $0.code == "pdf.linkTextUnavailable" }, "\(result.diagnostics)")
        }
    }
    func testUnsafeMissingAndActiveActionsNeverBecomeLinks() throws {
        let source = try PDFAnnotationFixture.make(in: root, extraLinks: true)
        let original = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(pdfTextRecognition: .disabled)))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(links(text), [PDFAnnotationFixture.encodedWeb, "#pmt-pdf-page-2"])
        for code in ["pdf.linkUnsafe", "pdf.linkUnavailable", "pdf.annotationActionNotRepresented"] { XCTAssertTrue(result.diagnostics.contains { $0.code == code }, code) }
        XCTAssertTrue(decoded(text).contains("javascript:never")); XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testAmbiguousRepeatedOrOverlappingTextRetainsSeparateTargets() throws {
        let source = try PDFAnnotationFixture.make(in: root, overlapping: true)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(pdfTextRecognition: .disabled)))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.linkTextUnavailable" })
        XCTAssertTrue(links(text).contains("mailto:second@example.com")); XCTAssertTrue(links(text).contains(PDFAnnotationFixture.encodedWeb))
        let body = text.components(separatedBy: "### Annotations")[0].replacingOccurrences(of: "\\_", with: "_")
        XCTAssertEqual(body.components(separatedBy: "WEB_LINK_LABEL").count - 1, 1)
    }
    func testOCRRasterExcludesAnnotationsAndRestoresDisplayState() throws {
        let source = try PDFAnnotationFixture.make(in: root)
        let original = try Data(contentsOf: source)
        let annotated = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        let plain = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        for annotation in plain.annotations { plain.removeAnnotation(annotation) }
        let adapter = PDFAdapter(), dimensions = try adapter.rasterDimensions(for: annotated)
        let a = try adapter.rasterImage(in: annotated, dimensions: dimensions)
        let b = try adapter.rasterImage(in: plain, dimensions: dimensions)
        XCTAssertEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
        XCTAssertTrue(annotated.displaysAnnotations); XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testImageOnlyPDFKeepsOCRAndAnnotationTextSeparate() throws {
        let source = try PDFAnnotationFixture.makeScan(in: root)
        let original = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(pdfTextRecognition: .always, ocrLanguages: ["en-US"], conversionReport: true)))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        let body = text.components(separatedBy: "### Annotations")[0]
        for token in ["SCANALPHA","SCANBETA"] { XCTAssertEqual(body.components(separatedBy: token).count - 1, 1, text) }
        XCTAssertFalse(body.contains("ANNOTATIONONLY")); XCTAssertEqual(decoded(text).components(separatedBy: "ANNOTATIONONLY").count - 1, 1)
        XCTAssertEqual(links(text), [PDFAnnotationFixture.encodedWeb]); XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.linkTextUnavailable" })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testAnnotationLimitsFailWithoutPublicationOrSourceChanges() throws {
        let limited = root.appendingPathComponent("limited.pdf")
        try PDFAnnotationFixture.limitDocument(annotationCount: 8_193).write(to: limited)
        XCTAssertEqual(PDFDocument(url: limited)?.page(at: 0)?.annotations.count, 8_193)
        let original = try Data(contentsOf: limited), output = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: limited, destination: .directory(output), options: .init(pdfTextRecognition: .disabled))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertEqual(try Data(contentsOf: limited), original)
    }
    func testRichTextOrphanPopupAndOffPageLinksRemainLiteralAndSeparate() throws {
        let source = root.appendingPathComponent("literal.pdf")
        try PDFAnnotationFixture.rawDocument(annotations: [
            "<< /Type /Annot /Subtype /Text /Rect [20 220 40 240] /RC (<b>RICH_ONLY</b> https://invalid.test) /T (Literal Author) /NM (original-annotation-id) >>",
            "<< /Type /Annot /Subtype /Popup /Rect [20 20 40 40] /Contents (ORPHAN_ONLY) >>",
            "<< /Type /Annot /Subtype /Link /Rect [-100 -100 -90 -90] /A << /S /URI /URI (mailto:fixture@example.com) >> >>"
        ]).write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(pdfTextRecognition: .disabled)))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(decoded(text).contains("original-annotation-id")); XCTAssertTrue(decoded(text).contains("Literal Author"))
        XCTAssertTrue(decoded(text).contains("<b>RICH_ONLY</b>")); XCTAssertFalse(text.contains("<b>"))
        XCTAssertEqual(decoded(text).components(separatedBy: "ORPHAN_ONLY").count - 1, 1)
        XCTAssertEqual(links(text), ["mailto:fixture@example.com"])
        for code in ["pdf.annotationRichTextLiteral", "pdf.annotationTypeNotRepresented", "pdf.annotationGeometryUnavailable", "pdf.linkTextUnavailable"] { XCTAssertTrue(result.diagnostics.contains { $0.code == code }, code) }
    }
    func testNamedStaticPageJumpsAreMappedAndMetadataLimitIsAtomic() throws {
        let source = try PDFAnnotationFixture.make(in: root)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: .init(x: -100,y: -100,width: 10,height: 10),forType: .link,withProperties: nil)
        annotation.action = PDFActionNamed(name: .nextPage); page.addAnnotation(annotation)
        let named = root.appendingPathComponent("named.pdf"); XCTAssertTrue(document.write(to: named))
        let result = try DocumentConverter().convert(.init(inputURL: named, options: .init(pdfTextRecognition: .disabled)))
        XCTAssertEqual(links(try String(contentsOf: result.markdownFile,encoding: .utf8)).filter { $0 == "#pmt-pdf-page-2" }.count, 2)
        let excessive = root.appendingPathComponent("excessive.pdf")
        try PDFAnnotationFixture.rawDocument(annotations: ["<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /T (" + String(repeating: "a",count: 65_537) + ") >>"]).write(to: excessive)
        let before = try Data(contentsOf: excessive), output = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: excessive,destination: .directory(output),options: .init(pdfTextRecognition: .disabled))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertEqual(try Data(contentsOf: excessive),before)
    }
}

enum PDFAnnotationFixture {
    static let web = "https://example.com/a(b)?x=1&y=two%20words"
    static let encodedWeb = "https://example.com/a%28b%29?x=1&y=two%20words"
    static let bodyTokens = ["BODY_ONE","WEB_LINK_LABEL","INTERNAL_LINK_LABEL","HIGHLIGHT_ONE","HIGHLIGHT_TWO","COMMENT_ANCHOR","UNSAFE_LABEL","MISSING_LABEL","ACTION_LABEL"]
    // Direkte PDF-Objekte vermeiden die quadratische Appearance-Erzeugung
    // von PDFKit beim Aufbau tausender unabhängiger Testannotationen.
    static func limitDocument(annotationCount: Int) -> Data {
        rawDocument(annotations: Array(repeating: "<< /Type /Annot /Subtype /Text /Rect [10 10 11 11] >>",count: annotationCount))
    }
    static func rawDocument(annotations: [String]) -> Data {
        let stream = "BT /F1 12 Tf 20 250 Td (BOUNDED_BODY remains readable.) Tj ET"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [" + annotations.indices.map { "\($0 + 6) 0 R" }.joined(separator: " ") + "] >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n" + stream + "\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        objects += annotations
        var data = Data("%PDF-1.4\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let start = data.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { xref += String(format: "%010d 00000 n \n", offset) }
        data.append(Data((xref + "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n").utf8))
        return data
    }
    private static func pdf(_ texts: [String], image: CGImage? = nil) -> Data {
        let data = NSMutableData(); var bounds = CGRect(x: 0,y: 0,width: 500,height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        for text in texts {
            context.beginPDFPage(nil)
            if let image { context.draw(image, in: bounds) }
            else { draw(text, in: context, bounds: CGRect(x: 30,y: 70,width: 440,height: 300), size: 16) }
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    private static func draw(_ text: String, in context: CGContext, bounds: CGRect, size: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: size)!])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(location: 0,length: 0), CGPath(rect: bounds,transform: nil), nil)
        CTFrameDraw(frame, context)
    }
    static func make(in root: URL, rotation: Int = 0, extraLinks: Bool = false, overlapping: Bool = false) throws -> URL {
        let text = "BODY_ONE embedded text remains readable.\nWEB_LINK_LABEL\nINTERNAL_LINK_LABEL\nHIGHLIGHT_ONE first marked line\nHIGHLIGHT_TWO second marked line\nCOMMENT_ANCHOR note reference\nUNSAFE_LABEL\nMISSING_LABEL\nACTION_LABEL"
        let document = PDFDocument(data: pdf([text,"BODY_TWO destination page remains readable."]))!
        let page = document.page(at: 0)!; page.rotation = rotation
        func rectangle(_ token: String) -> CGRect { page.selection(for: (page.string! as NSString).range(of: token))!.bounds(for: page) }
        let external = PDFAnnotation(bounds: rectangle("WEB_LINK_LABEL"), forType: .link, withProperties: nil); external.url = URL(string: web); page.addAnnotation(external)
        let internalLink = PDFAnnotation(bounds: rectangle("INTERNAL_LINK_LABEL"), forType: .link, withProperties: nil); internalLink.destination = PDFDestination(page: document.page(at: 1)!, at: CGPoint(x: 30,y: 350)); page.addAnnotation(internalLink)
        let first = rectangle("HIGHLIGHT_ONE"), second = rectangle("HIGHLIGHT_TWO"), union = first.union(second)
        let highlight = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
        var quadPoints: [NSValue] = []
        for rect in [first,second] {
            let left = rect.minX - union.minX, right = rect.maxX - union.minX
            let top = rect.maxY - union.minY, bottom = rect.minY - union.minY
            quadPoints.append(NSValue(point: NSPoint(x: left,y: top)))
            quadPoints.append(NSValue(point: NSPoint(x: right,y: top)))
            quadPoints.append(NSValue(point: NSPoint(x: left,y: bottom)))
            quadPoints.append(NSValue(point: NSPoint(x: right,y: bottom)))
        }
        highlight.quadrilateralPoints = quadPoints
        highlight.userName = "Highlighter"; page.addAnnotation(highlight)
        let comment = PDFAnnotation(bounds: rectangle("COMMENT_ANCHOR"), forType: .text, withProperties: nil)
        comment.contents = "COMMENT_BODY <script> [not a link](javascript:never) https://invalid.test"; comment.userName = "Reviewer <script>[x]"
        comment.modificationDate = ISO8601DateFormatter().date(from: "2026-10-16T10:11:12Z")!
        comment.setValue("D:20261016090000+02'00'", forAnnotationKey: PDFAnnotationKey(rawValue: "/CreationDate")); comment.setValue("note-fixture", forAnnotationKey: .name); page.addAnnotation(comment)
        let square = PDFAnnotation(bounds: CGRect(x: 10,y: 10,width: 20,height: 20), forType: .square, withProperties: nil); square.contents = "UNSUPPORTED_BODY"; page.addAnnotation(square)
        let popup = PDFAnnotation(bounds: CGRect(x: 20,y: 20,width: 200,height: 100), forType: .popup, withProperties: nil); comment.popup = popup; page.addAnnotation(popup)
        for generated in page.annotations where generated.type == "Popup" && generated !== popup && generated.contents?.isEmpty != false { page.removeAnnotation(generated) }
        if extraLinks {
            let unsafe = PDFAnnotation(bounds: rectangle("UNSAFE_LABEL"), forType: .link, withProperties: nil); unsafe.url = URL(string: "javascript:never"); page.addAnnotation(unsafe)
            let missing = PDFAnnotation(bounds: rectangle("MISSING_LABEL"), forType: .link, withProperties: nil); page.addAnnotation(missing)
            let action = PDFAnnotation(bounds: rectangle("ACTION_LABEL"), forType: .link, withProperties: nil); action.action = PDFActionNamed(name: .print); page.addAnnotation(action)
        }
        if overlapping { let duplicate = PDFAnnotation(bounds: rectangle("WEB_LINK_LABEL"),forType: .link,withProperties: nil); duplicate.url = URL(string: "mailto:second@example.com"); page.addAnnotation(duplicate) }
        let fixed = ISO8601DateFormatter().date(from: "2026-10-16T10:11:12Z")!
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Annotation fixture", PDFDocumentAttribute.authorAttribute: "Fixture Author", PDFDocumentAttribute.creationDateAttribute: fixed, PDFDocumentAttribute.modificationDateAttribute: fixed]
        for annotation in page.annotations {
            if annotation.type != "Text" && annotation.type != "Highlight" { annotation.userName = "Fixture Reviewer" }
            annotation.modificationDate = fixed
        }
        let path = root.appendingPathComponent("review.pdf"); guard document.write(to: path) else { throw CocoaError(.fileWriteUnknown) }; return path
    }
    static func makeScan(in root: URL) throws -> URL {
        let context = CGContext(data: nil,width: 1000,height: 800,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0,y: 0,width: 1000,height: 800))
        draw("SCANALPHA\nSCANBETA",in: context,bounds: CGRect(x: 100,y: 200,width: 800,height: 500),size: 64)
        let document = PDFDocument(data: pdf([""],image: context.makeImage()!))!, page = document.page(at: 0)!
        let comment = PDFAnnotation(bounds: CGRect(x: 30,y: 30,width: 440,height: 50),forType: .freeText,withProperties: nil); comment.contents = "ANNOTATIONONLY"; comment.font = NSFont(name: "Helvetica",size: 30)!; page.addAnnotation(comment)
        let link = PDFAnnotation(bounds: CGRect(x: 50,y: 240,width: 200,height: 60),forType: .link,withProperties: nil); link.url = URL(string: web); page.addAnnotation(link)
        let path = root.appendingPathComponent("scan.pdf"); guard document.write(to: path) else { throw CocoaError(.fileWriteUnknown) }; return path
    }
}
