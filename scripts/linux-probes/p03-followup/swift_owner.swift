import Foundation
import Glibc

@_silgen_name("pmt_pidfd_open") func pmt_pidfd_open(_ pid: Int32) -> Int32
@_silgen_name("pmt_pidfd_wait") func pmt_pidfd_wait(_ fd: Int32) -> Int32

// Eigenständiger P03-Harness, kein Ersatz des produktiven ProcessRunner.
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1], isDirectory: true)
let fixture = args[2]
let scenario = args[3]
let lifetime = Pipe()
let captureURL = root.appendingPathComponent("capture")
let infoURL = root.appendingPathComponent("namespace.json")
guard FileManager.default.createFile(atPath: captureURL.path, contents: nil),
      FileManager.default.createFile(atPath: infoURL.path, contents: nil) else { exit(125) }
let capture = try FileHandle(forWritingTo: captureURL)
let info = try FileHandle(forWritingTo: infoURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/bwrap")
process.arguments = ["--unshare-pid", "--unshare-net", "--as-pid-1", "--new-session",
    "--ro-bind", "/", "/", "--tmpfs", "/home", "--tmpfs", "/root",
    "--tmpfs", "/run", "--tmpfs", "/tmp", "--ro-bind", fixture, "/tmp/probe",
    "--bind", root.path, "/tmp/work", "--proc", "/proc", "--dev", "/dev",
    "--info-fd", "2", "/tmp/probe/guard", "/usr/bin/python3",
    "/tmp/probe/process_tree.py", "/tmp/work"]
if scenario == "main-exit" { process.arguments!.append("--exit-main") }
process.standardInput = lifetime
process.standardOutput = capture
process.standardError = info
try process.run()
let processFD = pmt_pidfd_open(process.processIdentifier)
guard processFD >= 0 else {
    try? lifetime.fileHandleForWriting.close()
    process.waitUntilExit()
    exit(125)
}
try lifetime.fileHandleForReading.close()
try String(process.processIdentifier).write(to: root.appendingPathComponent("wrapper.ready"),
                                           atomically: true, encoding: .utf8)
signal(SIGTERM, SIG_IGN)
let cancellation = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
cancellation.setEventHandler { try? lifetime.fileHandleForWriting.close() }
cancellation.resume()
// Erst nach der Identitätsbindung darf der Guard das Werkzeug starten.
try lifetime.fileHandleForWriting.write(contentsOf: Data([1]))
if scenario == "timeout" {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.ready").path),
          ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.005)
    }
    Thread.sleep(forTimeInterval: 0.1)
    try lifetime.fileHandleForWriting.close()
}
let observed = pmt_pidfd_wait(processFD)
try? lifetime.fileHandleForWriting.close()
close(processFD)
process.waitUntilExit()
try? lifetime.fileHandleForWriting.close()
try capture.close()
try info.close()
guard observed == 0 else { exit(125) }
if process.terminationReason == .uncaughtSignal { exit(128 + process.terminationStatus) }
exit(process.terminationStatus)
