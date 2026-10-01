import Foundation
import ImageIO
import XCTest
@testable import PoorMansTextCore

final class VerifiedImageSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-descriptor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func writeImage() throws -> URL {
        // Reguläre BMP mit zwei Pixeln; unabhängig vom ImageIO-Schreiber erzeugt.
        var bytes = [UInt8](repeating: 0, count: 62)
        func write(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        bytes[0] = 0x42; bytes[1] = 0x4D
        write(62, at: 2); write(54, at: 10); write(40, at: 14)
        write(2, at: 18); write(1, at: 22); bytes[26] = 1; bytes[28] = 24
        write(8, at: 34)
        let url = directory.appendingPathComponent("source.bmp")
        try Data(bytes).write(to: url)
        return url
    }

    private func open(_ url: URL) throws -> VerifiedFile.Owned {
        try VerifiedFile.openRetained(at: url) { _ in ImageAdapterError("fixture could not be opened") }
    }

    func testImageIOUsesCheckedObjectAfterPathReplacementWithFileAndFIFO() throws {
        for fifo in [false, true] {
            let url = try writeImage()
            let file = try open(url)
            let held = directory.appendingPathComponent("held-\(fifo).bmp")
            try FileManager.default.moveItem(at: url, to: held)
            if fifo { XCTAssertEqual(mkfifo(url.path, 0o600), 0) }
            else { try Data("replacement".utf8).write(to: url) }
            let image = try VerifiedImageSource(file: file)
            XCTAssertEqual(CGImageSourceGetType(image.source) as String?, "com.microsoft.bmp")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image.source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2)
            try image.validateUnchanged()
            try FileManager.default.removeItem(at: url)
        }
    }

    func testRejectsNonRegularSourcesWithoutBlocking() throws {
        let fifo = directory.appendingPathComponent("source.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for url in [fifo, directory!] {
            XCTAssertThrowsError(try VerifiedImageSource(at: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("not a regular file"))
            }
        }
    }

    func testPrivateSnapshotSurvivesTruncationForCloneAndStreamingFallback() throws {
        for allowClone in [false, true] {
            let url = try writeImage()
            let image = try VerifiedImageSource(file: open(url), allowClone: allowClone)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0); try handle.close()
            // ImageIO liest weiter sichere Snapshot-Bytes; die Gesamtprobe
            // meldet trotzdem die konkurrierende Änderung der Quelle.
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image.source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2)
            let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image.source, 0, nil))
            XCTAssertEqual(pixels.width, 2)
            XCTAssertThrowsError(try image.validateUnchanged())
        }
    }

    func testRejectsOversizedSourceBeforeImageIOReadsIt() throws {
        let url = try writeImage()
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ImageImportLimits.maximumSourceBytes) + 1)
        try handle.close()
        XCTAssertThrowsError(try VerifiedImageSource(at: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
    }

    func testDetectsTruncationGrowthAndSameSizeModification() throws {
        for change in ["truncate", "grow", "rewrite"] {
            let url = try writeImage()
            let image = try VerifiedImageSource(at: url)
            let handle = try FileHandle(forWritingTo: url)
            if change == "truncate" { try handle.truncate(atOffset: 20) }
            else if change == "grow" { try handle.truncate(atOffset: 63) }
            else {
                try handle.seek(toOffset: 54); try handle.write(contentsOf: Data([255]))
                // Dateisystem-Zeitauflösung unabhängig von der Geschwindigkeit des Tests.
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: url.path)
            }
            try handle.close()
            XCTAssertThrowsError(try image.validateUnchanged()) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed"))
            }
        }
    }

    func testDescriptorOwnerIsReleasedAfterImageSource() throws {
        let url = try writeImage()
        weak var weakFile: VerifiedFile.Owned?
        var image: VerifiedImageSource?
        var descriptor: Int32 = -1
        try autoreleasepool {
            let file = try open(url)
            descriptor = file.file.descriptor; weakFile = file
            image = try VerifiedImageSource(file: file)
        }
        XCTAssertNotNil(weakFile)
        XCTAssertNotNil(image)
        image = nil
        XCTAssertNil(weakFile)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    }
}
