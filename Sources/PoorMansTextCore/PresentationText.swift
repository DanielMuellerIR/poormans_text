import Foundation

struct PresentationText {
    struct Run {
        var text: String
        var target: String?
    }
    var runs: [Run] = []
    init(_ text: String = "") { if !text.isEmpty { runs = [.init(text: text)] } }
    var plainText: String { runs.map(\.text).joined() }
    var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }
    var maximumRenderedBytes: Int {
        runs.reduce(0) { bytes, run in
            bytes + run.text.utf8.count * 4 + (run.target.map { ($0.utf8.count * 6 + 8) * (run.text.filter { $0 == "\n" }.count + 1) } ?? 0)
        }
    }
    mutating func append(_ text: String, target: String? = nil) {
        guard !text.isEmpty else { return }
        if !runs.isEmpty, runs.last?.target == target { runs[runs.count - 1].text += text }
        else { runs.append(.init(text: text, target: target)) }
    }
    mutating func append(_ other: PresentationText) {
        for run in other.runs { append(run.text, target: run.target) }
    }
    func markdown(table: Bool, maximumBytes: Int) throws -> String {
        guard maximumRenderedBytes <= maximumBytes else { throw ImportFailure("presentation text or hyperlinks exceed the output budget") }
        guard runs.contains(where: { $0.target != nil }) else {
            return table ? MarkdownEscaping.inlineLiteral(plainText).replacingOccurrences(of: "\n", with: "<br>") : MarkdownEscaping.literalBlock(plainText)
        }
        // Erst den gesamten Quelltext maskieren, damit auch Blockmarker über
        // Run-Grenzen hinweg literal bleiben. Nur eigene Linkmarker ersetzen.
        let token = "PMTLINK" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var source = ImportTextBuilder(maximumBytes: maximumBytes)
        var links: [String] = []
        for run in runs {
            try ConversionExecution.check()
            guard let target = run.target else { try source.append(run.text); continue }
            for (index, line) in run.text.components(separatedBy: "\n").enumerated() {
                if index > 0 { try source.append("\n") }
                guard !line.isEmpty else { continue }
                try source.append(token + String(links.count) + "END")
                links.append("[" + MarkdownEscaping.inlineLiteral(line) + "](" + MarkdownEscaping.linkDestination(target) + ")")
            }
        }
        let escaped = table ? MarkdownEscaping.inlineLiteral(source.value).replacingOccurrences(of: "\n", with: "<br>") : MarkdownEscaping.literalBlock(source.value)
        let regex = try NSRegularExpression(pattern: token + "([0-9]+)END")
        var output = ImportTextBuilder(maximumBytes: maximumBytes)
        var cursor = escaped.startIndex
        for match in regex.matches(in: escaped, range: NSRange(escaped.startIndex..., in: escaped)) {
            try ConversionExecution.check()
            guard let range = Range(match.range, in: escaped), let digits = Range(match.range(at: 1), in: escaped),
                  let index = Int(escaped[digits]), links.indices.contains(index) else { throw ImportFailure("invalid presentation link marker") }
            try output.append(String(escaped[cursor..<range.lowerBound])); try output.append(links[index]); cursor = range.upperBound
        }
        try output.append(String(escaped[cursor...]))
        return output.value
    }
}

enum PresentationLinkTarget {
    static func external(_ raw: String) -> String? {
        DocumentLinkTarget.external(raw)
    }
    static func anchor(_ number: Int) -> String { "pmt-slide-\(number)" }
}
