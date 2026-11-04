#!/usr/bin/env python3
"""Kompiliert den vorhandenen ProcessRunner mit minimalen Test-Abhängigkeiten."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
args.destination.mkdir(parents=True, exist_ok=True)
runner = (repo / "Sources/PoorMansTextCore/ProcessRunner.swift").read_text()
runner = runner.replace("import Darwin", "import Glibc").replace("package ", "")
control = (repo / "Sources/PoorMansTextCore/ConversionControl.swift").read_text()
token = control[:control.index("/// Nur innerhalb")].replace("public ", "")
(args.destination / "Runner.swift").write_text(runner)
(args.destination / "Dependencies.swift").write_text(token + '''
enum ConversionError: Error, Sendable {
    case fileSystemFailure(String), processTimedOut, cancelled
}
enum ConversionExecution {
    struct Context {
        let cancellation: ConversionCancellationToken
        let processTimeout: TimeInterval?
    }
    static var current: Context? { nil }
}
''')
(args.destination / "main.swift").write_text('''
import Foundation
import Glibc
let lossProbe = CommandLine.arguments[1] == "--parent-loss"
let root = URL(fileURLWithPath: CommandLine.arguments[lossProbe ? 2 : 1], isDirectory: true)
func run(_ args: [String], token: ConversionCancellationToken? = nil,
         timeout: TimeInterval = 0.2, limit: Int = 16384) throws -> ProcessResult {
    try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: args, currentDirectory: root, captureStandardOutput: true,
        timeout: timeout, cancellation: token, maximumCapturedBytes: limit)
}
var checks: [String: Bool] = [:]
if lossProbe {
    _ = try run(["-c", "echo $$ > child.pid; sleep 30 & wait"], timeout: 30)
    exit(0)
}
let argument = "spaces;$(touch INJECTED) ä"
checks["argv"] = try run(["-c", "printf '%s' \\"$1\\"", "tool", argument]).standardOutput == argument
do {
    _ = try run(["-c", "trap '' TERM; sleep 30 & wait"])
    checks["timeout"] = false
} catch ConversionError.processTimedOut { checks["timeout"] = true }
let token = ConversionCancellationToken()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
do {
    _ = try run(["-c", "sleep 30 & wait"], token: token, timeout: 2)
    checks["cancel"] = false
} catch ConversionError.cancelled { checks["cancel"] = true }
do {
    _ = try run(["-c", "while :; do printf '%4096s' x; printf '%4096s' y >&2; done"], timeout: 2)
    checks["outputLimit"] = false
} catch ConversionError.fileSystemFailure(let message) {
    checks["outputLimit"] = message.contains("output limit")
}
checks["captureCleanup"] = try FileManager.default.contentsOfDirectory(atPath: root.path)
    .filter { $0.hasPrefix(".process-") }.isEmpty
let json = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
exit(checks.values.allSatisfy { $0 } ? 0 : 1)
''')
