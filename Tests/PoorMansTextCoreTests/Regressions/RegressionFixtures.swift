import Foundation
import XCTest

enum RegressionFixtures {
    private static let testDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let projectRoot = testDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func png() throws -> Data {
        try Data(contentsOf: testDirectory.appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
    }

    static func ods(meta: String) throws -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        <office:body><office:spreadsheet><table:table table:name="Blatt1">
        <table:table-row><table:table-cell office:value-type="string"><text:p>Wert</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        let metaXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <office:meta>\(meta)</office:meta>
        </office:document-meta>
        """
        return try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
                isStored: true
            ),
            ZIPFixtureBuilder.Entry(name: "content.xml", content: Data(content.utf8)),
            ZIPFixtureBuilder.Entry(name: "meta.xml", content: Data(metaXML.utf8)),
        ])
    }
}

extension XCTestCase {
    func makeRegressionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PMTRegression-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
