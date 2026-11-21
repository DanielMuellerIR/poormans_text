import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct CLIOutputError: LocalizedError {
    let code: Int32

    var errorDescription: String? {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return "Cannot write standard output: \(error.localizedDescription)"
    }
}

func writeOutput(_ data: Data) throws {
    try writeStream(data, to: STDOUT_FILENO)
}

func writeOutputLine(_ line: String) throws {
    try writeOutput(Data((line + "\n").utf8))
}

func writeDiagnostic(_ text: String) {
    try? writeStream(Data(text.utf8), to: STDERR_FILENO)
}

private func writeStream(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let start = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = write(descriptor, start.advanced(by: offset), buffer.count - offset)
            if count > 0 {
                offset += count
                continue
            }
            let code = count == 0 ? EIO : errno
            if code == EINTR { continue }
            throw CLIOutputError(code: code)
        }
    }
}
