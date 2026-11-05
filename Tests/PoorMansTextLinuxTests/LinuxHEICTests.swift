#if os(Linux)
import Foundation
import XCTest
@testable import PoorMansTextCore

final class LinuxHEICTests: XCTestCase {
    func testKnownImageDeclarationIncludesHEICWithoutDecoderAvailability() throws {
        let image = try XCTUnwrap(DocumentConverter().supportedFormatDescriptors.first { $0.format == .image })
        XCTAssertTrue(image.fileExtensions.contains("heic"))
        XCTAssertTrue(image.fileExtensions.contains("png"))
    }

    func testHEICHeaderDoesNotClaimAVIFOrUnboundedBrandBox() {
        var bytes: [UInt8] = [0, 0, 0, 20] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1".utf8)
        XCTAssertTrue(LinuxImageAdapter.isHEIC(Data(bytes)))
        bytes.replaceSubrange(8..<12, with: Array("avif".utf8))
        XCTAssertFalse(LinuxImageAdapter.isHEIC(Data(bytes)))
        bytes.replaceSubrange(8..<12, with: Array("heic".utf8))
        bytes[0] = 1
        XCTAssertFalse(LinuxImageAdapter.isHEIC(Data(bytes)))
        XCTAssertFalse(LinuxImageAdapter.isHEIC(Data("ftypheic".utf8)))
    }

    func testFolderEnumerationRetainsHEICWhenOptionalDecoderIsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pmt-heic-enumeration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for filename in ["photo.heic", "scan.png"] {
            try Data().write(to: directory.appendingPathComponent(filename))
        }
        let descriptor = SupportedFormat(format: .image, fileExtensions: ["png"], containerKind: .file, requiredTools: [])
        let enumerator = InputEnumerator(descriptors: [descriptor])
        let names = Set(try enumerator.enumerate([directory]).map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["photo.heic", "scan.png"])
        XCTAssertEqual(descriptor.fileExtensions, ["png"])
    }

    func testDecoderWorkerCannotReadUnboundSibling() throws {
        try LinuxBackendWorkDirectory.withTemporaryDirectory { sourceDirectory in
            let canary = sourceDirectory.appendingPathComponent("private-canary")
            let original = Data("private decoder canary".utf8)
            try original.write(to: canary)
            try LinuxBackendWorkDirectory.withTemporaryDirectory { output in
                let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-I", "-c", "import os,sys;print(os.path.exists(sys.argv[1]))", canary.path],
                    currentDirectory: output, captureStandardOutput: true, timeout: 5,
                    readOnlyPaths: [], writeScope: output)
                XCTAssertEqual(result.status, 0)
                XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "False")
                XCTAssertEqual(try Data(contentsOf: canary), original)
            }
        }
    }
}
#endif
