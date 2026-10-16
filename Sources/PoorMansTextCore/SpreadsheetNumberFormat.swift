import Foundation

enum SpreadsheetDateSystem: Sendable { case excel1900, excel1904, openDocument }

struct SpreadsheetFormattedNumber: Sendable {
    let text: String
    let issue: String?

    func warning(storedValue: String, at location: ConversionLocation) -> ConversionWarning? {
        guard let issue else { return nil }
        return ConversionWarning(
            code: "spreadsheet.numberFormatNotPreserved",
            message: text == storedValue
                ? "Number formatting could not be preserved: \(issue). The stored value was retained."
                : "Number formatting requires review: \(issue).",
            location: location
        )
    }
}

/// Kompiliert die unterstützte Excel-Formatsyntax einmal je Style. Bei einer
/// unbekannten Bedeutung bleibt der gespeicherte Wert statt einer Vermutung.
struct SpreadsheetNumberFormat: Sendable {
    private let sections: [Section]
    private let failure: String?

    init(code: String) {
        do {
            guard code.utf8.count <= 1_024 else { throw FormatError("the number format exceeds 1024 bytes") }
            let parts = try Self.splitSections(code)
            guard parts.count <= 4 else { throw FormatError("the number format has more than four sections") }
            sections = parts.prefix(3).map { Section(code: $0) }
            failure = nil
        } catch {
            sections = []
            failure = error.localizedDescription
        }
    }

    init(unsupported reason: String) {
        sections = []
        failure = reason
    }

    func format(_ rawValue: String, dateSystem: SpreadsheetDateSystem = .excel1900) -> SpreadsheetFormattedNumber {
        func fallback(_ reason: String) -> SpreadsheetFormattedNumber {
            .init(text: rawValue, issue: reason)
        }
        if let failure { return fallback(failure) }
        // General und als Text markierte Zahlen benötigen keine Präzisionswandlung.
        if sections.count == 1, case .general = sections[0].rendering {
            return .init(text: rawValue, issue: nil)
        }
        guard let value = Self.decimal(rawValue) else {
            return fallback("the stored number is outside the supported decimal precision or range")
        }
        let section: Section
        let implicitMinus: Bool
        if sections.contains(where: { $0.condition != nil }) {
            guard let selected = sections.first(where: { $0.condition?.matches(value) == true })
                    ?? sections.first(where: { $0.condition == nil }) else {
                return fallback("no conditional number-format section matches the value")
            }
            section = selected
            implicitMinus = value < 0
        } else {
            let index = value < 0 && sections.count >= 2 ? 1 : value == 0 && sections.count >= 3 ? 2 : 0
            section = sections[index]
            implicitMinus = value < 0 && index == 0
        }
        do {
            let magnitude = value < 0 ? -value : value
            let text: String
            var issue: String?
            switch section.rendering {
            case .general:
                text = rawValue
            case .unsupported(let reason): throw FormatError(reason)
            case .literal:
                throw FormatError("the number format replaces the stored number with a literal or hides it")
            case .number(let pattern):
                text = (implicitMinus ? "-" : "") + (try pattern.render(magnitude, symbols: section.symbols))
            case .date(let pattern):
                if !pattern.hasElapsedTime && value < 0 { throw FormatError("negative Excel dates or clock times have no supported representation") }
                let rendered = try pattern.render(magnitude, dateSystem: dateSystem, symbols: section.symbols)
                text = (implicitMinus ? "-" : "") + rendered.text
                issue = rendered.issue
            }
            guard !text.isEmpty else { throw FormatError("the number format hides the stored value") }
            guard text.utf8.count <= 4_096 else { throw FormatError("the formatted value exceeds 4096 bytes") }
            return .init(text: text, issue: issue)
        } catch { return fallback(error.localizedDescription) }
    }

    static func builtInCode(_ id: Int) -> String? {
        [0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
         9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
         14: "mm-dd-yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy",
         18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "m/d/yy h:mm",
         37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)",
         39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)",
         45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@"][id]
    }

    static func decimal(_ raw: String) -> Decimal? {
        guard !raw.isEmpty, raw.utf8.count <= 128 else { return nil }
        let bytes = Array(raw.utf8)
        var i = 0
        if bytes[i] == 43 || bytes[i] == 45 { i += 1 }
        var digits = 0
        while i < bytes.count && (48...57).contains(bytes[i]) { digits += 1; i += 1 }
        if i < bytes.count && bytes[i] == 46 {
            i += 1
            while i < bytes.count && (48...57).contains(bytes[i]) { digits += 1; i += 1 }
        }
        guard digits > 0 else { return nil }
        if i < bytes.count && (bytes[i] == 69 || bytes[i] == 101) {
            i += 1
            if i < bytes.count && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
            let start = i
            while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
            guard i > start else { return nil }
        }
        guard i == bytes.count else { return nil }
        let mantissa = raw.lowercased().split(separator: "e")[0].filter(\.isNumber)
        guard mantissa.drop(while: { $0 == "0" }).count <= 38,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    private static func splitSections(_ code: String) throws -> [String] {
        var parts = [""]
        var quoted = false
        var escaped = false
        var bracket = false
        for c in code {
            if escaped { parts[parts.count - 1].append(c); escaped = false; continue }
            if c == "\\" || (!quoted && (c == "_" || c == "*")) { escaped = true }
            if c == "\"" { quoted.toggle() }
            if !quoted && c == "[" { bracket = true }
            if !quoted && c == "]" { bracket = false }
            if c == ";" && !quoted && !bracket && !escaped { parts.append("") }
            else { parts[parts.count - 1].append(c) }
        }
        guard !quoted && !escaped && !bracket else { throw FormatError("the number format is unterminated") }
        return parts
    }

    private enum Token: Sendable, Equatable {
        case literal(String), digit(Character), decimal, comma, percent
        case date(Character, Int), elapsed(Character, Int), ampm(Bool), fraction(Int), exponent(Bool, Int)
        case general
    }

    private enum Rendering: Sendable {
        case general, literal(String), number(NumberPattern), date(DatePattern), unsupported(String)
    }

    private struct Condition: Sendable {
        let operation: String
        let value: Decimal
        func matches(_ candidate: Decimal) -> Bool {
            switch operation {
            case "<": candidate < value
            case "<=": candidate <= value
            case ">": candidate > value
            case ">=": candidate >= value
            case "=": candidate == value
            default: candidate != value
            }
        }
    }

    private struct Symbols: Sendable {
        let decimal: String
        let grouping: String
        let months: [String]
        let shortMonths: [String]
        let weekdays: [String]
        let shortWeekdays: [String]

        init(localeID: String) {
            let locale = Locale(identifier: localeID)
            let numbers = NumberFormatter()
            numbers.locale = locale
            decimal = numbers.decimalSeparator ?? "."
            grouping = numbers.groupingSeparator ?? ","
            let dates = DateFormatter()
            dates.locale = locale
            dates.calendar = Calendar(identifier: .gregorian)
            months = dates.monthSymbols
            shortMonths = dates.shortMonthSymbols
            weekdays = dates.weekdaySymbols
            shortWeekdays = dates.shortWeekdaySymbols
        }
        static let english = Symbols(localeID: "en_US_POSIX")
    }

    private struct Section: Sendable {
        let rendering: Rendering
        let condition: Condition?
        let symbols: Symbols

        init(code: String) {
            var predicate: Condition?
            var localeID = "en_US_POSIX"
            let parsedRendering: Rendering
            var parsedSymbols = Symbols.english
            do {
                let tokens = try Self.tokens(code, condition: &predicate, localeID: &localeID).filter { $0 != .literal("") }
                parsedSymbols = localeID == "en_US_POSIX" ? .english : Symbols(localeID: localeID)
                if tokens.contains(where: { if case .date = $0 { return true }; if case .elapsed = $0 { return true }; return false }) {
                    parsedRendering = .date(try DatePattern(tokens: tokens))
                } else if tokens == [.general] {
                    parsedRendering = .general
                } else if tokens.contains(where: { if case .digit = $0 { return true }; return false }) {
                    parsedRendering = .number(try NumberPattern(tokens: tokens))
                } else if tokens.allSatisfy({ if case .literal = $0 { return true }; return false }) {
                    parsedRendering = .literal(tokens.map { if case .literal(let s) = $0 { return s }; return "" }.joined())
                } else { throw FormatError("the number format contains unsupported syntax") }
            } catch {
                parsedRendering = .unsupported(error.localizedDescription)
            }
            rendering = parsedRendering
            condition = predicate
            symbols = parsedSymbols
        }

        private static func tokens(_ code: String, condition: inout Condition?, localeID: inout String) throws -> [Token] {
            let chars = Array(code)
            var output: [Token] = []
            var i = 0
            func starts(with value: String) -> Bool {
                i + value.count <= chars.count && String(chars[i..<(i + value.count)]).lowercased() == value
            }
            while i < chars.count {
                let c = chars[i]
                if c == "\"" {
                    i += 1
                    var literal = ""
                    while i < chars.count && chars[i] != "\"" { literal.append(chars[i]); i += 1 }
                    guard i < chars.count else { throw FormatError("a format literal is unterminated") }
                    output.append(.literal(literal))
                } else if c == "\\" || c == "_" || c == "*" {
                    i += 1
                    guard i < chars.count else { throw FormatError("a format escape is incomplete") }
                    if c == "\\" { output.append(.literal(String(chars[i]))) }
                } else if c == "[" {
                    let start = i + 1
                    while i < chars.count && chars[i] != "]" { i += 1 }
                    guard i < chars.count else { throw FormatError("a format bracket is unterminated") }
                    let bracket = String(chars[start..<i])
                    let lower = bracket.lowercased()
                    if ["h", "hh", "m", "mm", "s", "ss"].contains(lower) {
                        output.append(.elapsed(lower.first!, lower.count))
                    } else if lower.hasPrefix("$") {
                        let currency = String(bracket.dropFirst())
                        let pieces = currency.split(separator: "-", omittingEmptySubsequences: false)
                        guard pieces.count <= 2 else { throw FormatError("the format locale is unsupported") }
                        output.append(.literal(String(pieces[0])))
                        if pieces.count == 2 {
                            let locales = [0x409: "en_US_POSIX", 0x809: "en_GB", 0x407: "de_DE", 0x40c: "fr_FR",
                                           0x410: "it_IT", 0x40a: "es_ES", 0x411: "ja_JP", 0x413: "nl_NL",
                                           0x416: "pt_BR", 0x419: "ru_RU", 0x804: "zh_CN", 0x1009: "en_CA"]
                            guard let id = Int(pieces[1], radix: 16), let locale = locales[id] else {
                                throw FormatError("the format locale is unsupported")
                            }
                            localeID = locale
                        }
                    } else if ["black", "blue", "cyan", "green", "magenta", "red", "white", "yellow"].contains(lower)
                                || (lower.hasPrefix("color") && Int(lower.dropFirst(5)).map { (1...56).contains($0) } == true) {
                        // Farbe und Zellbreitenfüllung tragen keine Zahlenbedeutung.
                    } else {
                        let operation = String(bracket.prefix { "<>=!".contains($0) })
                        guard condition == nil, ["<", "<=", ">", ">=", "=", "<>"].contains(operation),
                              let value = SpreadsheetNumberFormat.decimal(String(bracket.dropFirst(operation.count))) else {
                            throw FormatError("the format contains an unsupported bracket expression")
                        }
                        condition = Condition(operation: operation, value: value)
                    }
                } else {
                    if starts(with: "general") { output.append(.general); i += 6 }
                    else if c == "@" { output.append(.general) }
                    else if starts(with: "am/pm") { output.append(.ampm(false)); i += 4 }
                    else if starts(with: "a/p") { output.append(.ampm(true)); i += 2 }
                    else if c.lowercased() == "e", i + 2 < chars.count, ["+", "-"].contains(chars[i + 1]), chars[i + 2] == "0" {
                        let plus = chars[i + 1] == "+"
                        i += 2
                        var width = 1
                        while i + 1 < chars.count && chars[i + 1] == "0" { width += 1; i += 1 }
                        guard width <= 4 else { throw FormatError("the exponent width is unsupported") }
                        output.append(.exponent(plus, width))
                    } else if "ymdhs".contains(c.lowercased()) {
                        let letter = Character(c.lowercased())
                        var count = 1
                        while i + 1 < chars.count && chars[i + 1].lowercased() == c.lowercased() { count += 1; i += 1 }
                        guard count <= 5, !(letter == "h" || letter == "s") || count <= 2,
                              letter != "d" || count <= 4 else { throw FormatError("the date token width is unsupported") }
                        output.append(.date(letter, count))
                    } else if c == "0" || c == "#" { output.append(.digit(c)) }
                    else if c == "." { output.append(.decimal) }
                    else if c == "," { output.append(.comma) }
                    else if c == "%" { output.append(.percent) }
                    else if c == "?" || c.isLetter { throw FormatError("fraction or other specialized formats are unsupported") }
                    else { output.append(.literal(String(c))) }
                }
                i += 1
            }
            return output
        }
    }

    private struct NumberPattern: Sendable {
        let prefix: String
        let suffix: String
        let minimumInteger: Int
        let fractional: [Character]
        let grouping: Bool
        let scale: Int
        let exponent: (plus: Bool, width: Int, step: Int)?

        init(tokens: [Token]) throws {
            let positions = tokens.indices.filter { if case .digit = tokens[$0] { return true }; return false }
            guard let first = positions.first, let last = positions.last else { throw FormatError("the number format has no digits") }
            let body = Array(tokens[first...last])
            guard body.allSatisfy({ if case .digit = $0 { return true }; return $0 == .decimal || $0 == .comma }),
                  body.filter({ $0 == .decimal }).count <= 1 else { throw FormatError("interleaved numeric format literals are unsupported") }
            let decimalIndex = body.firstIndex(of: .decimal) ?? body.count
            let integer = body[..<decimalIndex]
            fractional = body.dropFirst(min(body.count, decimalIndex + 1)).compactMap { if case .digit(let c) = $0 { return c }; return nil }
            guard !body.dropFirst(min(body.count, decimalIndex + 1)).contains(.comma), fractional.count <= 30 else {
                throw FormatError("the decimal precision or grouping is unsupported")
            }
            minimumInteger = integer.filter { $0 == .digit("0") }.count
            guard minimumInteger <= 128 else { throw FormatError("the integer padding exceeds 128 digits") }
            grouping = integer.contains(.comma)
            let trailing = Array(tokens.dropFirst(last + 1))
            var commas = 0
            while commas < trailing.count && trailing[commas] == .comma { commas += 1 }
            let percentages = tokens.filter { $0 == .percent }.count
            scale = percentages * 2 - commas * 3
            guard abs(scale) <= 18 else { throw FormatError("the numeric scaling is unsupported") }
            prefix = try Self.literal(Array(tokens.prefix(first)))
            suffix = try Self.literal(Array(trailing.dropFirst(commas)).filter { if case .exponent = $0 { return false }; return true })
            let exponents = trailing.compactMap { if case .exponent(let plus, let width) = $0 { return (plus, width) }; return nil }
            guard exponents.count <= 1 else { throw FormatError("multiple exponents are unsupported") }
            if let e = exponents.first {
                let count = integer.filter { if case .digit = $0 { return true }; return false }.count
                guard count == 1 || count == 3, !grouping else { throw FormatError("the scientific mantissa is unsupported") }
                exponent = (e.0, e.1, count)
            } else { exponent = nil }
        }

        private static func literal(_ tokens: [Token]) throws -> String {
            try tokens.map {
                switch $0 {
                case .literal(let s): return s
                case .percent: return "%"
                default: throw FormatError("the numeric affix is unsupported")
                }
            }.joined()
        }

        func render(_ value: Decimal, symbols: Symbols) throws -> String {
            var scaled = value
            var unscaled = value
            guard NSDecimalMultiplyByPowerOf10(&scaled, &unscaled, Int16(scale), .plain) == .noError else {
                throw FormatError("the scaled number exceeds decimal precision")
            }
            var exponentText = ""
            if let exponent {
                let number = NSDecimalNumber(decimal: scaled).doubleValue
                let power = number == 0 ? 0 : Int(floor(log10(number) / Double(exponent.step))) * exponent.step
                var original = scaled
                guard NSDecimalMultiplyByPowerOf10(&scaled, &original, Int16(-power), .plain) == .noError else {
                    throw FormatError("the scientific number exceeds decimal precision")
                }
                var rounded = Decimal()
                NSDecimalRound(&rounded, &scaled, fractional.count, .plain)
                var actualPower = power
                if NSDecimalNumber(decimal: rounded).doubleValue >= pow(10, Double(exponent.step)) {
                    original = scaled
                    _ = NSDecimalMultiplyByPowerOf10(&scaled, &original, Int16(-exponent.step), .plain)
                    actualPower += exponent.step
                }
                exponentText = "E" + (actualPower < 0 ? "-" : exponent.plus ? "+" : "")
                    + Self.pad(String(abs(actualPower)), to: exponent.width)
            }
            var rounded = Decimal()
            NSDecimalRound(&rounded, &scaled, fractional.count, .plain)
            let raw = NSDecimalNumber(decimal: rounded).stringValue
            guard !raw.lowercased().contains("e"), !rounded.isNaN else { throw FormatError("the rounded number exceeds decimal precision") }
            let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
            var integer = String(parts[0])
            if integer == "0", minimumInteger == 0 { integer = "" }
            integer = Self.pad(integer, to: minimumInteger)
            if grouping && !integer.isEmpty {
                let count = integer.count
                integer = integer.enumerated().map { index, c in
                    (index > 0 && (count - index) % 3 == 0 ? symbols.grouping : "") + String(c)
                }.joined()
            }
            var fraction = parts.count > 1 ? String(parts[1]) : ""
            fraction += String(repeating: "0", count: max(0, fractional.count - fraction.count))
            while fraction.count > 0 && fractional[fraction.count - 1] == "#" && fraction.last == "0" { fraction.removeLast() }
            return prefix + integer + (fraction.isEmpty ? "" : symbols.decimal + fraction) + exponentText + suffix
        }

        static func pad(_ text: String, to count: Int) -> String {
            String(repeating: "0", count: max(0, count - text.count)) + text
        }
    }

    private struct DatePattern: Sendable {
        let tokens: [Token]
        let fractionalDigits: Int
        let hasDate: Bool
        let hasElapsedTime: Bool

        init(tokens: [Token]) throws {
            var parsed: [Token] = []
            var i = 0
            var digits = 0
            while i < tokens.count {
                let token = tokens[i]
                if token == .decimal, let previous = parsed.last,
                   { if case .date("s", _) = previous { return true }; if case .elapsed("s", _) = previous { return true }; return false }() {
                    var count = 0
                    while i + 1 < tokens.count && tokens[i + 1] == .digit("0") { count += 1; i += 1 }
                    guard (1...6).contains(count) else { throw FormatError("fractional seconds require one to six zeros") }
                    digits = count
                    parsed.append(.fraction(count))
                } else {
                    switch token {
                    case .date, .elapsed, .ampm, .literal: parsed.append(token)
                    case .decimal: parsed.append(.literal("."))
                    case .comma: parsed.append(.literal(","))
                    default: throw FormatError("the date format contains unsupported numeric syntax")
                    }
                }
                i += 1
            }
            self.tokens = parsed
            fractionalDigits = digits
            hasElapsedTime = parsed.contains { if case .elapsed = $0 { return true }; return false }
            hasDate = parsed.contains { if case .date(let c, _) = $0 { return c == "y" || c == "d" }; return false }
                || parsed.indices.contains { if case .date("m", _) = parsed[$0] { return !Self.isMinute(at: $0, tokens: parsed) }; return false }
            guard !(hasDate && hasElapsedTime) else {
                throw FormatError("combined calendar and elapsed-time formats are unsupported")
            }
        }

        private static func isMinute(at index: Int, tokens: [Token]) -> Bool {
            let components = tokens.indices.filter { if case .date = tokens[$0] { return true }; if case .elapsed = tokens[$0] { return true }; return false }
            let previous = components.last { $0 < index }.map { tokens[$0] }
            let next = components.first { $0 > index }.map { tokens[$0] }
            if case .date("h", _) = previous { return true }
            if case .elapsed("h", _) = previous { return true }
            if case .date("s", _) = next { return true }
            if case .elapsed("s", _) = next { return true }
            return false
        }

        func render(_ value: Decimal, dateSystem: SpreadsheetDateSystem, symbols: Symbols) throws -> SpreadsheetFormattedNumber {
            let serial = NSDecimalNumber(decimal: value).doubleValue
            guard serial.isFinite, serial <= 2_958_465 else { throw FormatError("the date or duration is outside the supported range") }
            let precision = pow(10, Double(fractionalDigits))
            let ticks = Int64((serial * 86_400 * precision).rounded())
            let wholeSeconds = ticks / Int64(precision)
            let day = Int(wholeSeconds / 86_400)
            let seconds = Int(wholeSeconds % 86_400)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let baseComponents: DateComponents
            switch dateSystem {
            case .excel1900: baseComponents = DateComponents(year: 1899, month: 12, day: 31)
            case .excel1904: baseComponents = DateComponents(year: 1904, month: 1, day: 1)
            case .openDocument: baseComponents = DateComponents(year: 1899, month: 12, day: 30)
            }
            let base = calendar.date(from: baseComponents)!
            let leapDay = dateSystem == .excel1900 && day == 60
            if hasDate && dateSystem == .excel1900 && day == 0 { throw FormatError("Excel day zero has no Gregorian calendar date") }
            let offset = dateSystem == .excel1900 && day >= 60 ? day - 1 : day
            guard let date = calendar.date(byAdding: .day, value: offset, to: base) else { throw FormatError("the calendar date is invalid") }
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let year = components.year!, month = components.month!, calendarDay = leapDay ? 29 : components.day!
            guard year <= 9999 else { throw FormatError("the calendar date is beyond year 9999") }
            let hour = seconds / 3_600, minute = seconds / 60 % 60, second = seconds % 60
            let twelveHour = tokens.contains { if case .ampm = $0 { return true }; return false }
            var text = ""
            for (index, token) in tokens.enumerated() {
                switch token {
                case .literal(let s): text += s
                case .ampm(let short): text += hour < 12 ? (short ? "A" : "AM") : (short ? "P" : "PM")
                case .fraction(let count):
                    text += symbols.decimal + NumberPattern.pad(String(ticks % Int64(precision)), to: count)
                case .elapsed(let c, let count):
                    let total = c == "h" ? wholeSeconds / 3_600 : c == "m" ? wholeSeconds / 60 : wholeSeconds
                    text += NumberPattern.pad(String(total), to: count)
                case .date(let c, let count):
                    switch c {
                    case "y": text += count <= 2 ? NumberPattern.pad(String(year % 100), to: 2) : NumberPattern.pad(String(year), to: 4)
                    case "d":
                        if count >= 3 {
                            guard !leapDay else { throw FormatError("Excel's fictitious leap day has no Gregorian weekday") }
                            text += (count == 3 ? symbols.shortWeekdays : symbols.weekdays)[components.weekday! - 1]
                        } else { text += NumberPattern.pad(String(calendarDay), to: count) }
                    case "m":
                        if Self.isMinute(at: index, tokens: tokens) { text += NumberPattern.pad(String(minute), to: min(count, 2)) }
                        else if count >= 3 { text += count == 3 ? symbols.shortMonths[month - 1] : count == 5 ? String(symbols.months[month - 1].prefix(1)) : symbols.months[month - 1] }
                        else { text += NumberPattern.pad(String(month), to: count) }
                    case "h": text += NumberPattern.pad(String(twelveHour ? (hour % 12 == 0 ? 12 : hour % 12) : hour), to: min(count, 2))
                    default: text += NumberPattern.pad(String(second), to: min(count, 2))
                    }
                default: break
                }
            }
            return .init(text: text, issue: hasDate && leapDay ? "Excel serial 60 denotes the fictitious date 1900-02-29" : nil)
        }
    }

    private struct FormatError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
