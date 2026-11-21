import Darwin
import Foundation
import XCTest
@testable import PoorMansTextCore

final class MappedArchiveProcessRegressionTests: XCTestCase {
    /// Kürzt ein anderer Prozess eine abgebildete Datei, endet der nächste
    /// Zugriff hinter ihrem neuen Ende mit SIGBUS. Der Test läuft deshalb in
    /// einem eigenen XCTest-Prozess: Er dokumentiert den realen Absturz, ohne
    /// den gesamten Testlauf zu beenden. `ZIPArchiveInspector` darf nur seine
    /// unmittelbar zuvor geschriebene Staging-Kopie abbilden; fremde Quellen
    /// werden über begrenzte Deskriptorzugriffe gelesen.
    func testTruncatingAMappedArchiveCrashesOnlyTheChildProcess() throws {
        if let path = ProcessInfo.processInfo.environment["POORMANS_TEXT_MAPPED_ARCHIVE_CHILD"] {
            try crashAfterTruncatingMappedArchive(at: URL(fileURLWithPath: path))
            XCTFail("Der Zugriff auf die gekürzte Abbildung hätte SIGBUS auslösen müssen.")
            return
        }

        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("abgebildet.odt")
        try ZIPFixtureBuilder.archive(entries: [
            .init(
                name: "payload",
                content: Data(repeating: 0x41, count: 32 * 1_024),
                isStored: true
            ),
        ]).write(to: source)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "MappedArchiveProcessRegressionTests/testTruncatingAMappedArchiveCrashesOnlyTheChildProcess",
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["POORMANS_TEXT_MAPPED_ARCHIVE_CHILD"] = source.path
        process.environment = environment
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(
            process.terminationStatus,
            SIGBUS,
            String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private func crashAfterTruncatingMappedArchive(at source: URL) throws {
        let descriptor = open(source.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let length = Int(info.st_size)
        // Der zusätzliche Page-Rand erzwingt nach der Kürzung einen neuen
        // Dateisystemzugriff. Ein exakt bis zum alten Ende reichendes Mapping
        // darf auf aktuellem APFS noch aus dem Page-Cache antworten.
        let mappedLength = length + Int(getpagesize())
        guard let mapped = mmap(nil, mappedLength, PROT_READ, MAP_PRIVATE, descriptor, 0),
              mapped != MAP_FAILED else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(descriptor)
        // Der Austausch kommt von einem zweiten Prozess. Genau das entspricht
        // dem Cloud-Abgleich, der eine vom Import gerade gelesene Quelldatei
        // ersetzt; ein Kürzen durch denselben Prozess darf nicht als Test-Proxy
        // dafür dienen.
        let truncator = Process()
        truncator.executableURL = URL(fileURLWithPath: "/usr/bin/truncate")
        truncator.arguments = ["-s", "\(length / 2)", source.path]
        try truncator.run()
        truncator.waitUntilExit()
        guard truncator.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        // Bereits im Page-Cache liegende Bytes können den Fehler auf APFS bis
        // zum nächsten echten Seitenabruf verdecken. Das Advising verwirft sie
        // bewusst, damit der Zugriff wieder die nun gekürzte Datei befragen
        // muss.
        guard madvise(mapped, mappedLength, MADV_DONTNEED) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Das Schreiben in stdout verhindert, dass der Optimierer den Zugriff
        // wegfaltet. Genau dieser Bytezugriff trifft nach `truncate` die nicht
        // mehr gültige Seite der Abbildung.
        FileHandle.standardOutput.write(
            Data([mapped.load(fromByteOffset: mappedLength - 1, as: UInt8.self)])
        )
    }
}
