import Foundation
import PoorMansTextCore

let arguments = CommandLine.arguments.dropFirst()

if arguments == ["--version"] || arguments == ["-V"] {
    print("\(ProductInfo.name) \(ProductInfo.version)")
    exit(EXIT_SUCCESS)
}

let usage = """
Usage: poormans-text [--version]

The RTFD conversion command is under development.
"""

print(usage)

