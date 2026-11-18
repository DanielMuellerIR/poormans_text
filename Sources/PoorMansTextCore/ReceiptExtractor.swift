import Foundation

public enum ReceiptExtractor {
    public static func evaluate(_ mask: ReceiptMask, in document: ReceiptDocument) -> ReceiptResult {
        evaluate(mask, in: document, checkCancellation: {}, checkField: { _ in })
    }

    static func evaluateForExport(_ mask: ReceiptMask, in document: ReceiptDocument) throws -> ReceiptResult {
        var evidenceCount = 0
        var textBytes = 0
        return try evaluate(mask, in: document, checkCancellation: ConversionExecution.check) { field in
            evidenceCount += field.sources.count
            textBytes += field.value?.utf8.count ?? 0
            textBytes += field.sources.reduce(0) { $0 + $1.text.utf8.count }
            // Überlappende Regionen können denselben Text pro Feld erneut erfassen.
            guard evidenceCount <= 30_000, textBytes <= 2 * 1024 * 1024 else {
                throw ReceiptError.invalidDocument("The receipt result exceeds its text and evidence limit.")
            }
        }
    }

    private static func evaluate<Failure: Error>(
        _ mask: ReceiptMask, in document: ReceiptDocument,
        checkCancellation: () throws(Failure) -> Void, checkField: (ReceiptValue) throws(Failure) -> Void
    ) throws(Failure) -> ReceiptResult {
        var pages: [IndexedPage] = []
        for page in document.pages {
            try checkCancellation()
            pages.append(IndexedPage(page))
        }
        var fields: [ReceiptValue] = []
        for field in mask.fields {
            try checkCancellation()
            let value: ReceiptValue
            switch field.rule {
            case let .region(page, rectangle):
                value = region(field, page: page, rectangle: rectangle, in: pages)
            case let .rightOf(label, kind):
                let matches = try candidates(rightOf: label, kind: kind, in: pages, checkCancellation: checkCancellation)
                value = anchored(field, candidates: matches)
            }
            try checkField(value)
            fields.append(value)
        }
        return ReceiptResult(mask: mask, fields: fields)
    }

    public static func suggestions(in document: ReceiptDocument) -> [ReceiptField] {
        let pages = document.pages.map(IndexedPage.init)
        let groups: [(ReceiptValueKind, [(String, String)])] = [
            (.identifier, [("Rechnungsnummer", "Rechnungsnummer"), ("Rechnungs-Nr.", "Rechnungsnummer"),
                           ("Invoice number", "Invoice number"), ("Invoice no.", "Invoice number"),
                           ("Lieferscheinnummer", "Lieferscheinnummer"), ("Lieferschein-Nr.", "Lieferscheinnummer"),
                           ("Delivery note number", "Delivery note number"), ("Delivery note no.", "Delivery note number")]),
            (.date, [("Rechnungsdatum", "Rechnungsdatum"), ("Invoice date", "Invoice date"),
                     ("Lieferscheindatum", "Lieferscheindatum"), ("Delivery note date", "Delivery note date"),
                     ("Datum", "Datum"), ("Date", "Date")]),
        ]
        return groups.compactMap { kind, labels in
            for (label, name) in labels where !candidates(rightOf: label, kind: kind, in: pages, checkCancellation: {}).isEmpty {
                return ReceiptField(name: name, rule: .rightOf(label: label, kind: kind))
            }
            return nil
        }
    }

    private struct IndexedPage {
        struct Word {
            let original: ReceiptWord
            let label: String
            var bounds: CGRect { original.rectangle.cgRect }
        }

        let lines: [[Word]]
        let wordsByX: [Word]

        init(_ page: ReceiptPage) {
            let words = page.words.map { Word(original: $0, label: ReceiptExtractor.normalizeLabel($0.text)) }
            lines = Dictionary(grouping: words, by: { $0.original.line }).values.map { line in
                line.sorted { $0.bounds.minX < $1.bounds.minX }
            }.sorted {
                let a = $0[0].bounds
                let b = $1[0].bounds
                return a.midY == b.midY ? a.minX < b.minX : a.midY > b.midY
            }
            wordsByX = words.sorted { $0.bounds.minX < $1.bounds.minX }
        }

        func words(startingBetween minX: Double, and maxX: Double) -> ArraySlice<Word> {
            var lower = 0
            var upper = wordsByX.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if wordsByX[middle].bounds.minX < minX { lower = middle + 1 }
                else { upper = middle }
            }
            let end = wordsByX[lower...].firstIndex { $0.bounds.minX > maxX } ?? wordsByX.endIndex
            return wordsByX[lower..<end]
        }
    }

    private static func region(
        _ field: ReceiptField, page: Int, rectangle: ReceiptRectangle, in pages: [IndexedPage]
    ) -> ReceiptValue {
        guard pages.indices.contains(page), rectangle.isValid else { return missing(field) }
        let area = rectangle.cgRect
        let lines = pages[page].lines.map { line in
            line.filter { area.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
        }.filter { !$0.isEmpty }
        let sources = lines.flatMap { $0 }.map { evidence(for: $0.original, page: page) }
        guard !sources.isEmpty else { return missing(field) }
        let text = lines.map { $0.map(\.original.text).joined(separator: " ") }.joined(separator: "\n")
        return ReceiptValue(id: field.id, name: field.name, value: text,
                            status: .confirmed, sources: sources, diagnostic: nil)
    }

    private static func anchored(_ field: ReceiptField, candidates: [ReceiptEvidence]) -> ReceiptValue {
        guard let candidate = candidates.first else { return missing(field) }
        guard candidates.count == 1 else {
            return ReceiptValue(id: field.id, name: field.name, value: nil,
                                status: .ambiguous, sources: candidates,
                                diagnostic: "Multiple plausible values match this rule.")
        }
        return ReceiptValue(id: field.id, name: field.name, value: candidate.text,
                            status: .confirmed, sources: candidates, diagnostic: nil)
    }

    private static func candidates<Failure: Error>(
        rightOf label: String, kind: ReceiptValueKind, in pages: [IndexedPage],
        checkCancellation: () throws(Failure) -> Void
    ) throws(Failure) -> [ReceiptEvidence] {
        let labels = label.split(whereSeparator: \.isWhitespace).map { normalizeLabel(String($0)) }
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return [] }
        var matches: [ReceiptEvidence] = []
        var seen = Set<CandidateKey>()
        for (pageNumber, page) in pages.enumerated() {
            try checkCancellation()
            for line in page.lines where line.count >= labels.count {
                for index in 0...(line.count - labels.count) where line[index].label == labels[0] {
                    let tokens = line[index..<(index + labels.count)]
                    guard tokens.map(\.label) == labels,
                          zip(tokens, tokens.dropFirst()).allSatisfy({ $1.bounds.minX - $0.bounds.maxX <= 5 })
                    else { continue }
                    let anchor = tokens.reduce(CGRect.null) { $0.union($1.bounds) }
                    // Ein Wert rechts auf gleicher Höhe darf auch in einem separaten PDF-Textobjekt liegen.
                    for word in page.words(startingBetween: anchor.maxX - 0.3, and: anchor.maxX + 70)
                    where abs(word.bounds.midY - anchor.midY) <= min(word.bounds.height, anchor.height) * 0.55 {
                        let text = word.original.text
                        guard matchesKind(text, kind: kind) else { continue }
                        let key = CandidateKey(page: pageNumber, x: word.bounds.minX, y: word.bounds.minY, text: text)
                        if seen.insert(key).inserted { matches.append(evidence(for: word.original, page: pageNumber)) }
                    }
                }
            }
        }
        return matches.sorted {
            if $0.page != $1.page { return $0.page < $1.page }
            if $0.rectangle.y != $1.rectangle.y { return $0.rectangle.y > $1.rectangle.y }
            return $0.rectangle.x < $1.rectangle.x
        }
    }

    private struct CandidateKey: Hashable {
        let page: Int
        let x: Double
        let y: Double
        let text: String
    }

    private static func normalizeLabel(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ":."))
    }

    private static func matchesKind(_ text: String, kind: ReceiptValueKind) -> Bool {
        let date = isDate(text)
        switch kind {
        case .date:
            return date
        case .identifier:
            return !date && text.count <= 64 && text.utf8.contains(where: { (48...57).contains($0) })
                && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
        }
    }

    private static func isDate(_ text: String) -> Bool {
        guard text.utf8.count <= 10 else { return false }
        let separators = text.filter { ".-/".contains($0) }
        guard separators.count == 2, separators.first == separators.last, let separator = separators.first
        else { return false }
        let parts = text.split(separator: separator)
        guard parts.count == 3, parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let first = Int(parts[0]), let month = Int(parts[1]), let last = Int(parts[2]) else { return false }
        let year: Int
        let day: Int
        if parts[0].count == 4, separator == "-", parts[1].count == 2, parts[2].count == 2 {
            year = first
            day = last
        } else if parts[0].count <= 2, parts[1].count <= 2, parts[2].count == 4 {
            year = last
            day = first
        } else {
            return false
        }
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return false }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        return day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    private static func evidence(for word: ReceiptWord, page: Int) -> ReceiptEvidence {
        ReceiptEvidence(page: page, rectangle: word.rectangle, text: word.text, origin: word.origin)
    }

    private static func missing(_ field: ReceiptField) -> ReceiptValue {
        ReceiptValue(id: field.id, name: field.name, value: nil, status: .missing, sources: [],
                     diagnostic: "No value matches this rule.")
    }
}
