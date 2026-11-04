import Foundation
import PoorMansTextCore
let args = CommandLine.arguments
let input = URL(fileURLWithPath:args[1])
let token = ConversionCancellationToken()
if args.contains("--cancel") { token.cancel() }
do {
 let result = try DocumentConverter().convert(ConversionRequest(inputURL:input,destination:.directory(URL(fileURLWithPath:args[2])),options:.init(conversionReport:true)),cancellation:token)
 print("OK \(result.format.rawValue) assets=\(result.assets.count) markdown=\(result.markdownFile.path)")
} catch {
 FileHandle.standardError.write(Data("ERROR \(error.localizedDescription)\n".utf8)); exit(1)
}
