import Foundation

enum L10n { static func string(_ value: String) -> String { value }; static func format(_ value: String, _ args: CVarArg...) -> String { String(format: value, arguments: args) } }
func check(_ label: String, _ condition: Bool) {
    guard condition else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}
@main struct ContractProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pmt-consumer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
        let catalog = MarkdownImportCatalog.decode(try data("catalog.json"))!
        check("catalog unknown fields", catalog.toolVersion == "0.41.7")
        check("mbox accepts file", catalog.format(forExtension: "mbox")!.supportsContainer(isDirectory: false))
        check("mbox accepts package", catalog.format(forExtension: "mbox")!.supportsContainer(isDirectory: true))
        check("unavailable tool", !catalog.format(forExtension: "doc")!.isAvailable)
        let output = MarkdownImportOutput.decode(try data("single.json"))!
        check("single warnings", output.warnings == ["Verlustprobe"])
        check("unknown fields ignored", output.assets.isEmpty)
        check("minimal optional fields", MarkdownImportOutput.decode(try data("minimal.json")) != nil)
        check("broken JSON rejected", MarkdownImportOutput.decode(try data("broken.json")) == nil)
        check("error rejected", MarkdownImportOutput.decode(try data("error.json")) == nil)
        check("error text", MarkdownImportOutput.decodeError(try data("error.json")) == "Probe: Werkzeug fehlt")
        let collection = MarkdownImportOutput.decode(try data("collection.json"))!
        check("collection decodes but reports no assets", collection.assets.isEmpty)
        let allowed = scratch.appendingPathComponent("tree/out")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: allowed.appendingPathComponent("source.md"))
        try Data("foreign".utf8).write(to: scratch.appendingPathComponent("foreign.md"))
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("linked-out"), withDestinationURL: allowed)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("link.md"), withDestinationURL: allowed.appendingPathComponent("source.md"))
        check("valid file guard", MarkdownImportOutputGuard.isPublishableFile(allowed.appendingPathComponent("source.md"), in: allowed))
        check("foreign path rejected", !MarkdownImportOutputGuard.isPublishableFile(scratch.appendingPathComponent("foreign.md"), in: allowed))
        check("symlink root rejected", !MarkdownImportOutputGuard.isPublishableFile(scratch.appendingPathComponent("linked-out/source.md"), in: scratch.appendingPathComponent("linked-out")))
        check("symlink file rejected", !MarkdownImportOutputGuard.isPublishableFile(allowed.appendingPathComponent("link.md"), in: allowed))
        func progress(_ name: String, _ suffix: String) -> MarkdownImportProgress? {
            var parser = MarkdownImportProgressParser(sourceName: name)
            return parser.consume(Data("Progress: \(name): \(suffix)\n".utf8))
        }
        check("colon and slash source", progress("ä: phase / 1.docx", "converting page 1/2")?.completed == 1)
        check("unknown note unit ignored", progress("a.enex", "converting note 1/2") == nil)
        check("unknown message unit ignored", progress("a.mbox", "converting message 1/2") == nil)
        check("unknown chapter unit ignored", progress("a.epub", "converting chapter 1/2") == nil)
        check("count without total ignored", progress("a.pdf", "converting page 1") == nil)
        check("newline source cannot parse", progress("a\nb.pdf", "converting page 1/2") == nil)
        var parser = MarkdownImportProgressParser(sourceName: "ä.pdf")
        let bytes = Data("Progress: ä.pdf: converting page 1/2\n".utf8)
        var value: MarkdownImportProgress?
        for byte in bytes { if let result = parser.consume(Data([byte])) { value = result } }
        check("one-byte UTF8 chunks", value?.completed == 1)
        let scenario = scratch.appendingPathComponent("collection-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: true)
        let source = scenario.appendingPathComponent("mail.mbox")
        try Data("original source".utf8).write(to: source)
        let service = MarkdownImportService()
        service.locateTool = { URL(fileURLWithPath: "/fake-test-hook") }
        service.runProcess = { _, arguments, _, _, completion in
            let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--output")! + 1])
            try! FileManager.default.createDirectory(at: output.appendingPathComponent("documents"), withIntermediateDirectories: true)
            let index = output.appendingPathComponent("mail.md")
            try! Data("[One](documents/one.md)\n[Two](documents/two.md)\n".utf8).write(to: index)
            for name in ["one", "two"] {
                try! Data(name.utf8).write(to: output.appendingPathComponent("documents/\(name).md"))
            }
            let json: [String: Any] = ["ok": true, "markdownFile": index.path, "assets": [], "documents": [["sourceIndex": 1, "markdownFile": output.appendingPathComponent("documents/one.md").path], ["sourceIndex": 2, "markdownFile": output.appendingPathComponent("documents/two.md").path]]]
            completion(MarkdownImportProcessOutcome(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: json), stderr: Data(), outputIsComplete: true))
            return nil
        }
        var published: URL?
        service.convert(source) { published = $0 }
        check("real service reports collection success", published != nil)
        let sourceText = try String(contentsOf: source, encoding: .utf8)
        check("source unchanged", sourceText == "original source")
        check("synthetic assets-empty reply removes children (robustness gap)", !FileManager.default.fileExists(atPath: scenario.appendingPathComponent("documents/one.md").path))
        let indexText = try String(contentsOf: published!, encoding: .utf8)
        check("synthetic assets-empty reply retains broken links (robustness gap)", indexText.contains("documents/one.md"))
        let records = try JSONSerialization.jsonObject(with: data("producer-records.json")) as! [String: [String: Any]]
        check("real producer catalog accepted", MarkdownImportCatalog.decode(try data("producer-catalog.json")) != nil)
        for name in ["mail.mbox", "notes.enex"] {
            let record = records[name]!
            let reply = record["json"] as! [String: Any]
            let scenario = scratch.appendingPathComponent("real-collection-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: true)
            let source = scenario.appendingPathComponent(name)
            try Data("untouched source".utf8).write(to: source)
            let service = MarkdownImportService()
            service.locateTool = { URL(fileURLWithPath: "/fake-test-hook") }
            service.runProcess = { _, args, _, _, completion in
                let out = URL(fileURLWithPath: args[args.firstIndex(of: "--output")! + 1])
                let markdown = record["markdown"] as! [String: String]
                for (relative, text) in markdown {
                    let file = out.appendingPathComponent(relative)
                    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try! Data(text.utf8).write(to: file)
                }
                let originalRoot = reply["outputDirectory"] as! String
                let raw = String(data: try! JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!
                let originalJSON = try! JSONSerialization.data(withJSONObject: originalRoot, options: .fragmentsAllowed)
                let targetJSON = try! JSONSerialization.data(withJSONObject: out.path, options: .fragmentsAllowed)
                // JSON-Pfadpräfixe ersetzen; die restliche Originalantwort bleibt erhalten.
                let from = String(data: originalJSON, encoding: .utf8)!.dropFirst().dropLast()
                let to = String(data: targetJSON, encoding: .utf8)!.dropFirst().dropLast()
                let relocated = raw.replacingOccurrences(of: String(from), with: String(to))
                completion(MarkdownImportProcessOutcome(exitCode: 0, stdout: Data(relocated.utf8), stderr: Data(), outputIsComplete: true))
                return nil
            }
            var returned: URL?
            service.convert(source) { returned = $0 }
            check("\(name) real producer service reports success", returned != nil)
            check("\(name) real producer tree retained", FileManager.default.fileExists(atPath: scenario.appendingPathComponent(source.deletingPathExtension().lastPathComponent+"/index.md").path))
            check("\(name) wrong returned Markdown path (known failure)", !FileManager.default.fileExists(atPath: returned!.path))
        }
        print("NOTE: Original Fastra service publication executed using its existing runProcess injection hook; UI/framework and process runner are stubs. No real process cancellation acceptance.")
    }
}
