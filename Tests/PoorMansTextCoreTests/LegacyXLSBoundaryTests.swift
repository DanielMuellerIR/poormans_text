import Foundation
import XCTest
@testable import PoorMansTextCore

final class LegacyXLSBoundaryTests: XCTestCase {
    func testGeneratedBIFFWorkbookProducesExactIndependentOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextGeneratedXLS-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Generated.xls")
        try SyntheticXLSFixture.workbook(missingFirstSheetEOF: false).write(to: sourceURL)

        let workbook = try LegacyXLSWorkbookParser.parse(
            Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        )
        let markdown = SpreadsheetMarkdownRenderer.render(
            workbook,
            sourceURL: sourceURL,
            style: .markdownTable
        )

        XCTAssertEqual(
            markdown,
            """
            # Generated

            ## Sheet: First

            | 1 |
            | --- |

            ## Sheet: Second

            |  | 2 |
            | --- | --- |
            """ + "\n"
        )
        XCTAssertEqual(workbook.sheets.map(\.name), ["First", "Second"])
    }

    func testWorksheetWithoutOwnEOFStopsAtTheNextPhysicalSheet() throws {
        let document = SyntheticXLSFixture.workbook(missingFirstSheetEOF: true)

        XCTAssertThrowsError(try LegacyXLSWorkbookParser.parse(document)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "an XLS worksheet has no EOF before the next sheet"
            )
        }
    }

    func testNonWorksheetBoundSheetStillEndsThePreviousWorksheet() throws {
        let document = SyntheticXLSFixture.workbook(
            missingFirstSheetEOF: true,
            interveningChart: true
        )

        XCTAssertThrowsError(try LegacyXLSWorkbookParser.parse(document)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "an XLS worksheet has no EOF before the next sheet"
            )
        }
    }
}

/// Erzeugt eine vollständige OLE-Compound-Datei mit einem kleinen BIFF8-Stream.
/// Das Fixture stammt damit nicht aus dem getesteten Parser und kann gezielt ein
/// fehlendes Blatt-EOF abbilden, ohne eine versionierte Binärdatei umzuschreiben.
private enum SyntheticXLSFixture {
    static func workbook(missingFirstSheetEOF: Bool, interveningChart: Bool = false) -> Data {
        let firstSheet = sheet(column: 0, value: 1, includeEOF: !missingFirstSheetEOF)
        let chartSheet = interveningChart ? nonWorksheetSheet(type: 0x0020) : Data()
        let secondSheet = sheet(column: 1, value: 2, includeEOF: true)

        let placeholderGlobals = globals(
            firstOffset: 0,
            chartOffset: interveningChart ? 0 : nil,
            secondOffset: 0
        )
        let firstOffset = placeholderGlobals.count
        let chartOffset = interveningChart ? firstOffset + firstSheet.count : nil
        let secondOffset = firstOffset + firstSheet.count + chartSheet.count
        var stream = globals(
            firstOffset: firstOffset,
            chartOffset: chartOffset,
            secondOffset: secondOffset
        )
        stream.append(firstSheet)
        stream.append(chartSheet)
        stream.append(secondSheet)
        precondition(stream.count <= 4_096)
        stream.append(Data(repeating: 0, count: 4_096 - stream.count))

        var header = Data(repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.setUInt16(0x003E, at: 24)
        header.setUInt16(3, at: 26)
        header.setUInt16(0xFFFE, at: 28)
        header.setUInt16(9, at: 30)
        header.setUInt16(6, at: 32)
        header.setUInt32(1, at: 44)             // ein FAT-Sektor
        header.setUInt32(8, at: 48)             // Verzeichnis-Sektor
        header.setUInt32(4_096, at: 56)
        header.setUInt32(0xFFFF_FFFE, at: 60)   // keine MiniFAT
        header.setUInt32(0, at: 64)
        header.setUInt32(0xFFFF_FFFE, at: 68)   // keine DIFAT-Kette
        header.setUInt32(0, at: 72)
        for index in 0..<109 { header.setUInt32(0xFFFF_FFFF, at: 76 + index * 4) }
        header.setUInt32(9, at: 76)             // FAT liegt in Sektor 9

        var directory = Data(repeating: 0, count: 512)
        writeDirectoryEntry(
            name: "Root Entry",
            type: 5,
            startSector: 0xFFFF_FFFE,
            size: 0,
            at: 0,
            in: &directory
        )
        writeDirectoryEntry(
            name: "Workbook",
            type: 2,
            startSector: 0,
            size: 4_096,
            at: 128,
            in: &directory
        )

        var fat = Data(repeating: 0xFF, count: 512)
        for sector in 0..<7 { fat.setUInt32(UInt32(sector + 1), at: sector * 4) }
        fat.setUInt32(0xFFFF_FFFE, at: 7 * 4)
        fat.setUInt32(0xFFFF_FFFE, at: 8 * 4)
        fat.setUInt32(0xFFFF_FFFD, at: 9 * 4)

        var document = header
        document.append(stream)
        document.append(directory)
        document.append(fat)
        return document
    }

    private static func globals(firstOffset: Int, chartOffset: Int?, secondOffset: Int) -> Data {
        var result = record(0x0809, payload: bof(type: 0x0005))
        result.append(record(0x0085, payload: boundSheet(offset: firstOffset, name: "First")))
        if let chartOffset {
            result.append(record(
                0x0085,
                payload: boundSheet(offset: chartOffset, name: "Chart", type: 2)
            ))
        }
        result.append(record(0x0085, payload: boundSheet(offset: secondOffset, name: "Second")))
        result.append(record(0x000A, payload: Data()))
        return result
    }

    private static func sheet(column: UInt16, value: Double, includeEOF: Bool) -> Data {
        var result = record(0x0809, payload: bof(type: 0x0010))
        var number = Data()
        number.appendUInt16(0)       // Zeile
        number.appendUInt16(column)
        number.appendUInt16(0)       // XF-Index
        number.appendUInt64(value.bitPattern)
        result.append(record(0x0203, payload: number))
        if includeEOF { result.append(record(0x000A, payload: Data())) }
        return result
    }

    private static func nonWorksheetSheet(type: UInt16) -> Data {
        var result = record(0x0809, payload: bof(type: type))
        result.append(record(0x000A, payload: Data()))
        return result
    }

    private static func bof(type: UInt16) -> Data {
        var payload = Data()
        payload.appendUInt16(0x0600)
        payload.appendUInt16(type)
        return payload
    }

    private static func boundSheet(offset: Int, name: String, type: UInt8 = 0) -> Data {
        var payload = Data()
        payload.appendUInt32(UInt32(offset))
        payload.append(0)            // sichtbar
        payload.append(type)
        payload.append(UInt8(name.utf8.count))
        payload.append(0)            // komprimierte 8-Bit-Zeichen
        payload.append(contentsOf: name.utf8)
        return payload
    }

    private static func record(_ id: UInt16, payload: Data) -> Data {
        var result = Data()
        result.appendUInt16(id)
        result.appendUInt16(UInt16(payload.count))
        result.append(payload)
        return result
    }

    private static func writeDirectoryEntry(
        name: String,
        type: UInt8,
        startSector: UInt32,
        size: UInt32,
        at offset: Int,
        in directory: inout Data
    ) {
        var nameBytes = Data()
        for unit in name.utf16 { nameBytes.appendUInt16(unit) }
        nameBytes.appendUInt16(0)
        directory.replaceSubrange(offset..<(offset + nameBytes.count), with: nameBytes)
        directory.setUInt16(UInt16(nameBytes.count), at: offset + 64)
        directory[offset + 66] = type
        directory.setUInt32(startSector, at: offset + 116)
        directory.setUInt32(size, at: offset + 120)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8(value >> UInt32(shift) & 0xFF))
        }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8(value >> UInt64(shift) & 0xFF))
        }
    }

    mutating func setUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8)
    }

    mutating func setUInt32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 {
            self[offset + byte] = UInt8(value >> UInt32(byte * 8) & 0xFF)
        }
    }
}
