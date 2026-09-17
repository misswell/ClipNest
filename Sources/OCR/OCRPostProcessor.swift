import Foundation

/// Conservative cleanup of raw Vision output (spec §37).
///
/// The guiding rule is "fix layout, never fix facts". OCR errors inside `HTTP`, `JSON`,
/// `Swift`, code, numbers and identifiers are left exactly as recognized — a plausible
/// correction is far more damaging than a visible typo, because the note is supposed to be
/// a faithful record of the source.
enum OCRPostProcessor {
    struct Options: Equatable, Sendable {
        /// Join lines that Vision split mid-sentence.
        var mergesWrappedLines = true
        /// Rejoin `exam-\nple` into `example` (Latin only).
        var repairsHyphenatedBreaks = true
        /// Drop lines that repeat like a page header/footer.
        var removesRepeatedLines = true
        /// A line must repeat at least this often before it counts as a header/footer.
        var repeatedLineThreshold = 3
        var maximumRepeatedLineLength = 60

        static let `default` = Options()
    }

    static func process(_ rawText: String, options: Options = .default) -> String {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized
            .components(separatedBy: "\n")
            .map { collapseSpaces($0) }

        if options.removesRepeatedLines {
            lines = removingRepeatedLines(lines, options: options)
        }
        if options.repairsHyphenatedBreaks {
            lines = repairingHyphenation(lines)
        }
        if options.mergesWrappedLines {
            lines = mergingWrappedLines(lines)
        }
        lines = collapsingBlankLines(lines)

        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Steps

    /// Trailing/duplicated spaces. Leading indentation is meaningful, so it is preserved.
    static func collapseSpaces(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = String(line.dropFirst(leading.count))
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        return String(leading) + body
    }

    /// A page header or footer shows up on most pages. Only short, punctuation-free lines
    /// qualify, so a repeated code line or a repeated hashtag survives.
    private static func removingRepeatedLines(_ lines: [String], options: Options) -> [String] {
        var counts: [String: Int] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= options.maximumRepeatedLineLength else { continue }
            counts[trimmed, default: 0] += 1
        }
        let repeated = Set(counts.filter { $0.value >= options.repeatedLineThreshold }.keys)
        guard !repeated.isEmpty else { return lines }

        var kept: [String] = []
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if repeated.contains(trimmed) {
                // Keep the first occurrence only when it is the document's very first line
                // (that is usually the real title rather than a running header).
                if kept.isEmpty && seen.isEmpty {
                    seen.insert(trimmed)
                    kept.append(line)
                }
                continue
            }
            kept.append(line)
        }
        return kept
    }

    /// `exam-` + `ple` → `example`. Latin-only, lowercase on both sides, so real dashes in
    /// prose and ranges in identifiers are untouched.
    private static func repairingHyphenation(_ lines: [String]) -> [String] {
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let current = lines[index]
            if index + 1 < lines.count,
               current.hasSuffix("-"),
               !current.hasSuffix("--"),
               let lastCharacter = current.dropLast().last,
               lastCharacter.isLowercase,
               let nextFirst = lines[index + 1].first,
               nextFirst.isLowercase,
               !looksLikeCode(current) {
                output.append(String(current.dropLast()) + lines[index + 1])
                index += 2
                continue
            }
            output.append(current)
            index += 1
        }
        return output
    }

    /// Vision reports one visual line at a time. Join a wrapped line onto the previous one
    /// when the previous line has no terminal punctuation and the next line continues it.
    private static func mergingWrappedLines(_ lines: [String]) -> [String] {
        var output: [String] = []
        for line in lines {
            guard let previous = output.last,
                  shouldMerge(previous: previous, next: line)
            else {
                output.append(line)
                continue
            }
            let separator = needsSpace(previous: previous, next: line) ? " " : ""
            output[output.count - 1] = previous.trimmingCharacters(in: .whitespaces) + separator
                + line.trimmingCharacters(in: .whitespaces)
        }
        return output
    }

    private static func shouldMerge(previous: String, next: String) -> Bool {
        // Leading indentation means code or a nested block, not a wrapped line. This has to
        // be checked on the raw line, before trimming throws the indentation away.
        guard !next.hasPrefix(" "), !next.hasPrefix("\t") else { return false }

        let left = previous.trimmingCharacters(in: .whitespaces)
        let right = next.trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return false }
        guard !looksLikeCode(left), !looksLikeCode(right) else { return false }
        guard !startsBlock(right) else { return false }
        // A finished sentence is not continued by the next line.
        let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "；", ";", "：", ":"]
        guard let last = left.last, !terminalPunctuation.contains(last) else { return false }
        // Vision also ends a paragraph mid-word when the next line starts lowercase.
        if let first = right.first, first.isLowercase { return true }
        // Chinese has no inter-word spaces, so an unterminated CJK line almost always wraps.
        if let lastScalar = left.unicodeScalars.last,
           LocalLanguageProfile.isCJK(lastScalar) {
            return true
        }
        return false
    }

    /// Block starts (headings, list items, quotes, table rows, fenced code) are never merged.
    private static func startsBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
        if line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
        if line.hasPrefix("+ ") { return true }
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return true }
        // Ordered list: "1. ", "12) "
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return true }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(") ") { return true }
        return false
    }

    /// Crude code detector used only to disable text-joining heuristics.
    static func looksLikeCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let codeSignals = ["{", "}", ";", "=>", "->", "==", "()", "$", "\\"]
        if codeSignals.contains(where: { trimmed.contains($0) }) { return true }
        if trimmed.hasSuffix(",") && trimmed.contains(":") { return true }
        let keywords = ["func ", "let ", "var ", "def ", "class ", "import ", "return ", "public ", "private ", "const ", "SELECT ", "INSERT "]
        return keywords.contains { trimmed.contains($0) }
    }

    /// Chinese does not use spaces, so joining must not insert one.
    private static func needsSpace(previous: String, next: String) -> Bool {
        guard let lastScalar = previous.trimmingCharacters(in: .whitespaces).unicodeScalars.last,
              let firstScalar = next.trimmingCharacters(in: .whitespaces).unicodeScalars.first
        else { return false }
        if LocalLanguageProfile.isCJK(lastScalar) || LocalLanguageProfile.isCJK(firstScalar) {
            return false
        }
        return true
    }

    private static func collapsingBlankLines(_ lines: [String]) -> [String] {
        var output: [String] = []
        var pendingBlank = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBlank = !output.isEmpty
                continue
            }
            if pendingBlank { output.append("") }
            pendingBlank = false
            output.append(line)
        }
        return output
    }
}
