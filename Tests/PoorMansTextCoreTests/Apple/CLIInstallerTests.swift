import Foundation
import XCTest
@testable import PoorMansTextAppSupport

final class CLIInstallerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var sourceURL: URL!
    private var targetURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIInstallerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        sourceURL = temporaryDirectory.appendingPathComponent("Poor Man's Text.app/Contents/Resources/poormans-text")
        targetURL = temporaryDirectory.appendingPathComponent("bin with space/poormans-text")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: sourceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceURL.path)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testReportsAvailableInstalledAndConflictingTargets() throws {
        XCTAssertEqual(CLIInstaller.status(sourceURL: sourceURL, targetURL: targetURL), .available)

        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: sourceURL)
        XCTAssertEqual(CLIInstaller.status(sourceURL: sourceURL, targetURL: targetURL), .installed)

        try FileManager.default.removeItem(at: targetURL)
        try Data("foreign".utf8).write(to: targetURL)
        XCTAssertEqual(CLIInstaller.status(sourceURL: sourceURL, targetURL: targetURL), .conflict)
    }

    func testInstallQuotesApostrophesAndSpacesAndVerifiesLink() throws {
        try CLIInstaller.install(
            sourceURL: sourceURL,
            targetURL: targetURL,
            administratorPrivileges: false
        )

        XCTAssertEqual(CLIInstaller.status(sourceURL: sourceURL, targetURL: targetURL), .installed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: targetURL.path),
            sourceURL.path
        )
    }

    func testDoesNotReplaceTargetCreatedBeforeInstallation() throws {
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: targetURL)

        XCTAssertThrowsError(
            try CLIInstaller.install(
                sourceURL: sourceURL,
                targetURL: targetURL,
                administratorPrivileges: false
            )
        )
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "foreign")
    }
}
