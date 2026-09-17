import Foundation

/// Title selection for Local Lite (spec §11).
///
/// Order: Markdown H1 → Markdown H2 → first substantial sentence → top keywords →
/// "Untitled Note". Length caps differ by script (30 Chinese characters, 80 Latin) and are
/// applied at a word boundary, never mid-token, and never by cutting into a code span.
enum LocalTitleExtractor {
    static let chineseMaximumLength = 30
    static let latinMaximumLength = 80
    static var fallbackTitle: String { String(localized: "Untitled Note") }

    static func title(for text: String, preferredLanguage: PreferredLanguage = .automatic) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return fallbackTitle }
        // A bare link is material, never a title.
        if isBareURL(body) { return fallbackTitle }

        if let heading = firstHeading(in: body, level: 1) { return finalize(heading) }
        if let heading = firstHeading(in: body, level: 2) { return finalize(heading) }

        if let sentence = LocalTextAnalyzer.sentences(in: body, minimumLength: 8).first {
            let candidate = finalize(sentence)
            if isAcceptable(candidate) { return candidate }
        }

        let keywords = LocalTextAnalyzer.keywords(in: body, limit: 3)
            .filter { !$0.isEmpty && !LocalTextAnalyzer.isURLToken($0) }
        if !keywords.isEmpty {
            let candidate = finalize(keywords.joined(separator: " "))
            if isAcceptable(candidate) { return candidate }
        }

        return fallbackTitle
    }

    /// True when the whole input is one URL with no prose around it.
    static func isBareURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n") else { return false }
        return LocalTextAnalyzer.isURLToken(trimmed)
    }

    private static func firstHeading(in text: String, level: Int) -> String? {
        LocalTextAnalyzer.markdownHeadings(in: text)
            .first { $0.level == level && isAcceptable($0.text) }?
            .text
    }

    /// A candidate is unusable when it is punctuation, a bare URL, or only Markdown syntax.
    static func isAcceptable(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        guard !LocalTextAnalyzer.isURLToken(trimmed) else { return false }
        // Reject anything that is only symbols/digits.
        let hasLetter = trimmed.unicodeScalars.contains {
            LocalLanguageProfile.isCJK($0) || LocalLanguageProfile.isLatinLetter($0)
        }
        guard hasLetter else { return false }
        // A whole paragraph is not a title.
        return trimmed.count <= 400
    }

    /// Strips Markdown, collapses whitespace and applies the script-aware length cap.
    static func finalize(_ raw: String) -> String {
        var value = LocalTextAnalyzer.cleanInline(raw)
        value = value.replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t.-–—:：,，;；"))
        guard !value.isEmpty else { return fallbackTitle }

        let profile = LocalLanguageProfile.analyze(value)
        let limit = profile.isChineseDominant ? chineseMaximumLength : latinMaximumLength
        guard value.count > limit else { return value }
        return truncate(value, to: limit, chineseDominant: profile.isChineseDominant)
    }

    /// Truncation that never splits a Latin word and never leaves a dangling connector.
    private static func truncate(_ value: String, to limit: Int, chineseDominant: Bool) -> String {
        let prefix = String(value.prefix(limit))
        var candidate = prefix
        if !chineseDominant, let lastSpace = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: lastSpace) >= limit / 2 {
            candidate = String(prefix[prefix.startIndex..<lastSpace])
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—:：,，;；、。.!"))
        // Do not end on a connector word that only makes sense with what follows.
        let dangling: Set<String> = ["and", "or", "the", "a", "an", "of", "to", "in", "on", "with", "for", "使用", "以及", "和"]
        if let last = candidate.split(separator: " ").last, dangling.contains(last.lowercased()) {
            candidate = candidate.split(separator: " ").dropLast().joined(separator: " ")
        }
        return candidate.isEmpty ? prefix : candidate
    }
}

/// Conservative Markdown tidying for Local Lite bodies (spec §36). It never rewrites facts:
/// it only normalizes line endings, trims trailing whitespace, and collapses the runs of
/// blank lines that OCR and copy/paste leave behind. Fenced code blocks are passed through
/// byte for byte.
enum MarkdownContentCleaner {
    static func clean(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var output: [String] = []
        var insideFence = false
        var pendingBlankLines = 0

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushBlankLines(&output, count: &pendingBlankLines)
                output.append(line)
                insideFence.toggle()
                continue
            }
            if insideFence {
                output.append(line)
                continue
            }
            if trimmed.isEmpty {
                pendingBlankLines += 1
                continue
            }
            flushBlankLines(&output, count: &pendingBlankLines)
            output.append(collapseSpaces(line))
        }

        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }

    private static func flushBlankLines(_ output: inout [String], count: inout Int) {
        guard count > 0 else { return }
        if !output.isEmpty { output.append("") }
        count = 0
    }

    /// Collapses runs of spaces that copy/paste from PDFs and web pages produce, but leaves
    /// indentation (which is meaningful in Markdown) and table rows alone.
    private static func collapseSpaces(_ line: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)
        var cleaned = body.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        // Preserve table alignment pipes by not touching rows that contain them.
        if cleaned.contains("|") { return line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        return String(leading) + cleaned
    }
}

/// The always-available local engine (spec §10–§13, §36).
///
/// It is deliberately *not* an LLM. It extracts a title, extracts a summary, extracts tags,
/// classifies semantically, and passes the original body through a conservative cleaner —
/// so it cannot hallucinate and stays under the performance budget.
struct LocalLiteNoteProvider: NoteGenerating {
    var profiles: [CategoryProfile]
    var classifier: LocalSemanticClassifier
    var summarizer: LocalSummarizer
    var tagExtractor: LocalTagExtractor

    init(profiles: [CategoryProfile] = [],
         classifier: LocalSemanticClassifier = LocalSemanticClassifier(),
         summarizer: LocalSummarizer = LocalSummarizer(),
         tagExtractor: LocalTagExtractor = LocalTagExtractor()) {
        self.profiles = profiles
        self.classifier = classifier
        self.summarizer = summarizer
        self.tagExtractor = tagExtractor
    }

    /// Human-readable name of the engine behind local generation.
    static var engineName: String { String(localized: "ClipNest Local Lite") }

    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        let text = content.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIError.emptyInput
        }

        let title = LocalTitleExtractor.title(for: text, preferredLanguage: preferredLanguage)
        let summary = summarizer.summarize(text, title: title)
        let body = MarkdownContentCleaner.clean(text)

        let effectiveProfiles = profiles.isEmpty
            ? existingCategories.map { CategoryProfile(name: $0) }
            : profiles
        let result = classifier.classify(text: text, categories: effectiveProfiles)

        return GeneratedNote(title: title,
                             summary: summary,
                             content: body,
                             category: result.category ?? "",
                             tags: tagExtractor.tags(in: text, title: title),
                             sourceURL: content.sourceURL)
    }
}
