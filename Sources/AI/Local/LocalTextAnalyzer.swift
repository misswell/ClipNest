import Foundation
import NaturalLanguage

/// Pure-Foundation / NaturalLanguage text analysis: the lexical backbone of Local Lite.
///
/// Everything here is deterministic, allocation-light, and free of network or model
/// downloads. It never invents content — it only measures what is already in the text.
enum LocalTextAnalyzer {
    /// A scored lexical term.
    struct Term {
        let text: String
        /// Normalized form used for counting and de-duplication.
        let key: String
        let count: Int
        let isTechnical: Bool
        /// Position of first appearance, used to break score ties in document order so the
        /// term the author mentioned first wins.
        let order: Int
    }

    /// Hard cap on how much text lexical scoring looks at. A 1 MB paste still returns
    /// instantly; the tail only ever contributes noise to a keyword ranking.
    static let maximumAnalyzedCharacters = 60_000

    /// A Chinese run longer than this is a clause, not a word: it contributes bi-grams but
    /// is not itself kept as a term.
    static let maximumWholeRunLength = 6

    // MARK: - Sentences

    /// Sentence segmentation for extractive summarization. Code blocks, bare URLs and
    /// fragments shorter than `minimumLength` are dropped because they never read well as
    /// a summary line.
    static func sentences(in text: String, minimumLength: Int = 12) -> [String] {
        let withoutCode = strippingCodeBlocks(from: text)
        var output: [String] = []

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = withoutCode
        tokenizer.enumerateTokens(in: withoutCode.startIndex..<withoutCode.endIndex) { range, _ in
            let sentence = normalizeSentence(String(withoutCode[range]))
            if sentence.count >= minimumLength { output.append(sentence) }
            return true
        }

        // NLTokenizer occasionally drops a full line when a paste mixes scripts heavily,
        // so any substantial line it missed is appended in document order.
        if output.isEmpty {
            output = withoutCode
                .components(separatedBy: "\n")
                .map { normalizeSentence($0) }
                .filter { $0.count >= minimumLength }
        }
        return output
    }

    private static func normalizeSentence(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tokens

    /// Real word tokens only: `NLTokenizer` segments plus script runs, with the overlapping
    /// bi-grams that `tokens(in:)` adds for search recall deliberately excluded.
    ///
    /// This distinction is user-visible. `tokens(in:)` decomposes the CJK run `图片文字识别`
    /// into `图片`, `片文`, `文字`, `字识`, `识别` so a dictionary-free search can still find
    /// the text; `片文` and `字识` are word *fragments* that cut across real boundaries. They
    /// are harmless as index terms and unacceptable as tags, which is what this entry point is
    /// for.
    static func wordTokens(in text: String) -> [String] {
        let bounded = String(text.prefix(maximumAnalyzedCharacters))
        var collector = TokenCollector()

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = bounded
        tokenizer.enumerateTokens(in: bounded.startIndex..<bounded.endIndex) { range, _ in
            collector.append(String(bounded[range]))
            return true
        }

        // Latin script runs are unioned in because the system tokenizer drops tokens where two
        // scripts touch (`MySQL和Spring`), and because it can split a technical token such as
        // `zh-Hans`. CJK runs are *not* unioned: the system tokenizer already segments Chinese
        // correctly (`图片文字识别` → `图片`/`文字`/`识别`), and adding the CJK runs back is
        // exactly what reintroduces the crossing bi-grams `片文` and `字识`.
        for token in scriptRuns(in: bounded) where !token.contains(where: { character in
            character.unicodeScalars.contains { LocalLanguageProfile.isCJK($0) }
        }) {
            collector.append(token)
        }
        return collector.tokens
    }

    /// Words for keyword/tag work.
    ///
    /// The system tokenizer is the primary source, but it silently drops tokens where a
    /// Chinese and a Latin run touch (`MySQL和Spring` loses both `和` and `Spring`), so a
    /// script-run scanner is unioned in. That scanner is also what keeps `SwiftUI`,
    /// `VNRecognizeTextRequest` and `C++` in one piece.
    static func tokens(in text: String) -> [String] {
        let bounded = String(text.prefix(maximumAnalyzedCharacters))
        var collector = TokenCollector()

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = bounded
        tokenizer.enumerateTokens(in: bounded.startIndex..<bounded.endIndex) { range, _ in
            collector.append(String(bounded[range]))
            return true
        }

        for token in scriptRuns(in: bounded) {
            collector.append(token)
        }
        return collector.tokens
    }

    /// De-duplicates tokens by `normalizedKey`, preferring the more specific spelling when two
    /// different tokens collapse to the same key.
    ///
    /// `normalizedKey` trims trailing punctuation, so `C++`, `C#` and `C` all key to `c`. Plain
    /// set-membership deduplication therefore dropped `C++` and `C#` in favour of whichever
    /// spelling happened to arrive first — the module comment promised `C++` was kept "in one
    /// piece" while the tokenizer was in fact returning a bare `C`.
    private struct TokenCollector {
        private var indexByKey: [String: Int] = [:]
        private(set) var tokens: [String] = []

        mutating func append(_ token: String) {
            let key = normalizedKey(token)
            guard !key.isEmpty else { return }
            if let existing = indexByKey[key] {
                guard token.count > tokens[existing].count else { return }
                tokens[existing] = token
                return
            }
            indexByKey[key] = tokens.count
            tokens.append(token)
        }
    }

    /// Splits text into runs of CJK characters and runs of Latin/digit/technical characters.
    /// CJK runs longer than four characters additionally yield their bi-grams, which is the
    /// standard dictionary-free way to recover Chinese terms.
    static func scriptRuns(in text: String) -> [String] {        var output: [String] = []
        var current = ""
        var currentIsCJK = false

        func flush() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            if currentIsCJK {
                // Chinese has no spaces, so a longer run is only ever a substring of the
                // text, not a word. Keeping the run *and* its bi-grams gives recall (a
                // dictionary-free matcher can find 睡眠 inside 注意睡眠和饮食健康) while the
                // bi-grams stay short enough to be useful as tags and titles.
                if current.count >= 2, current.count <= maximumWholeRunLength {
                    output.append(current)
                }
                if current.count >= 3 {
                    let characters = Array(current)
                    for index in 0..<(characters.count - 1) {
                        output.append(String(characters[index...index + 1]))
                    }
                }
            } else {
                output.append(current)
            }
        }

        for character in text {
            let isCJK = character.unicodeScalars.contains { LocalLanguageProfile.isCJK($0) }
            let isWordCharacter = isCJK
                || character.isLetter
                || character.isNumber
                || technicalPunctuation.contains(character)

            guard isWordCharacter else {
                flush()
                continue
            }
            if current.isEmpty {
                currentIsCJK = isCJK
            } else if isCJK != currentIsCJK {
                flush()
                currentIsCJK = isCJK
            }
            current.append(character)
        }
        flush()
        return output
    }

    /// Characters that may legally appear inside a technical token.
    private static let technicalPunctuation: Set<Character> = ["+", "#", "_", ".", "-", "@", "/"]

    // MARK: - Terms and keywords

    /// Frequency-ranked terms, technical vocabulary weighted up so `SwiftUI` outranks a
    /// generic word that happens to repeat.
    static func terms(in text: String, limit: Int = 24) -> [Term] {
        rank(tokens: tokens(in: text), limit: limit)
    }

    /// The same ranking over real words only. Use this wherever the result is shown to the
    /// user (tags, keyword titles), so recall bi-grams like `片文` never become visible.
    static func wordTerms(in text: String, limit: Int = 24) -> [Term] {
        rank(tokens: wordTokens(in: text), limit: limit)
    }

    private static func rank(tokens: [String], limit: Int) -> [Term] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        var technical: Set<String> = []
        var firstSeen: [String: Int] = [:]

        for (position, token) in tokens.enumerated() {
            let key = normalizedKey(token)
            // A lone Chinese character is almost always a segmentation artifact ("慢",
            // "最", "用") rather than a keyword, so a two-character floor applies to every
            // script.
            guard !key.isEmpty,
                  !stopwords.contains(key),
                  key.count >= 2,
                  !isURLToken(token),
                  !isNumberOnly(key)
            else { continue }

            counts[key, default: 0] += 1
            if display[key] == nil {
                display[key] = canonicalDisplay(for: token)
                firstSeen[key] = position
            }
            if isTechnicalTerm(token) { technical.insert(key) }
        }

        // A bi-gram that only ever appears inside a longer kept word is redundant. Only
        // word-shaped keys may subsume: a nine-character clause contains every bi-gram in
        // it, but it is not a term, so it must not delete them.
        let longerKeys = counts.keys.filter { $0.count > 2 && isWordShaped($0) }
        let redundant = Set(counts.keys.filter { key in
            guard key.count == 2 else { return false }
            return longerKeys.contains { $0 != key && $0.contains(key) && counts[$0, default: 0] >= counts[key, default: 0] }
        })

        let ranked = counts
            .filter { !redundant.contains($0.key) }
            .map { key, count -> (key: String, count: Int, technical: Bool, order: Int) in
                (key, count, technical.contains(key) || isTechnicalTerm(display[key] ?? key), firstSeen[key] ?? .max)
            }
            .sorted { lhs, rhs in
                let lhsScore = score(count: lhs.count, technical: lhs.technical, key: lhs.key)
                let rhsScore = score(count: rhs.count, technical: rhs.technical, key: rhs.key)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.order < rhs.order
            }
            .prefix(limit)

        return ranked.map {
            Term(text: display[$0.key] ?? $0.key,
                 key: $0.key,
                 count: $0.count,
                 isTechnical: $0.technical,
                 order: $0.order)
        }
    }

    /// Top keywords, word-shaped only — these end up in titles and tag chips, so the
    /// recall bi-grams are excluded (see `wordTokens(in:)`).
    static func keywords(in text: String, limit: Int = 8) -> [String] {
        wordTerms(in: text, limit: limit).map(\.text)
    }

    /// Heuristic term weight: frequency, plus a bonus for technical tokens and for the
    /// lengths that real tags tend to have (2–4 Chinese characters, 3–20 Latin characters).
    static func score(count: Int, technical: Bool, key: String) -> Double {
        var value = Double(count) * (technical ? 2.2 : 1.0)
        if key.count >= 2 && key.count <= 4 { value *= 1.35 }
        else if key.count > 24 { value *= 0.5 }
        return value
    }

    // MARK: - Markdown helpers

    static func strippingCodeBlocks(from text: String) -> String {
        var output: [String] = []
        var insideFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if trimmed.hasPrefix("    ") && trimmed.count > 4 { continue }  // indented code
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// ATX headings in document order.
    static func markdownHeadings(in text: String) -> [(level: Int, text: String)] {
        var output: [(level: Int, text: String)] = []
        var insideFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, trimmed.hasPrefix("#") else { continue }
            let hashes = trimmed.prefix { $0 == "#" }
            guard hashes.count <= 6 else { continue }
            let rest = trimmed.dropFirst(hashes.count)
            guard rest.first == " " || rest.isEmpty else { continue }
            let title = cleanInline(String(rest))
            if !title.isEmpty { output.append((hashes.count, title)) }
        }
        return output
    }

    /// Removes inline Markdown noise without touching code or URLs.
    static func cleanInline(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "[#>*_]+", with: " ", options: .regularExpression)
        return value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isURLToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
    }

    /// True when the whole block is a fenced code listing. Used to keep the search chunker
    /// from sentence-splitting code.
    static func looksLikeFencedCode(_ block: String) -> Bool {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("    ")
    }

    static func normalizedKey(_ token: String) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`*_#-+@ "))
    }

    private static func isNumberOnly(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == ":" }
    }

    /// Keeps the author's casing for technical terms; lowercases ordinary words so the same
    /// word never shows up twice in a tag list.
    private static func canonicalDisplay(for token: String) -> String {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`*_"))
        guard !trimmed.isEmpty else { return token }
        if isTechnicalTerm(trimmed) { return trimmed }
        return trimmed.lowercased()
    }

    // MARK: - Technical vocabulary

    /// Terms that must survive tokenization even when the tokenizer wants to split them.
    static let protectedTechnicalTerms: Set<String> = [
        "swiftui", "uikit", "appkit", "foundationmodels", "coredata", "coreml", "coremltools",
        "xcode", "xcodegen", "swiftpm", "combine", "asyncsequence", "nstextview", "nslayoutconstraint",
        "vision", "vnrecognizetextrequest", "vnimagerequesthandler", "avfoundation", "metal",
        "mysql", "postgresql", "postgres", "sqlite", "redis", "mongodb", "elasticsearch",
        "springboot", "spring", "hibernate", "mybatis", "numpy", "pandas", "pytorch", "tensorflow",
        "react", "vue", "svelte", "nextjs", "nodejs", "typescript", "javascript", "webpack", "vite",
        "claudecode", "openai", "chatgpt", "gpt", "llm", "rag", "langchain",
        "obsidian", "icloud", "dropbox", "notion", "docker", "kubernetes", "k8s", "nginx", "linux",
        "github", "gitlab", "json", "yaml", "toml", "http", "https", "rest", "graphql", "grpc",
        "sql", "nosql", "jwt", "oauth", "cors", "cdn", "dns", "tcp", "udp", "ssh", "tls"
    ]

    /// True for curated terms, acronyms, CamelCase identifiers and dotted/plussed names.
    /// True when a term is short enough to be a word or phrase rather than a whole clause.
    /// Used to stop a long Chinese run from deleting the meaningful bi-grams inside it.
    static func isWordShaped(_ key: String) -> Bool {
        if key.count <= 4 { return true }
        if isTechnicalTerm(key) { return true }
        // Latin words are delimited by spaces, so length is not a signal there.
        let first = key.unicodeScalars.first
        return !(first.map(LocalLanguageProfile.isCJK) ?? false)
    }

    static func isTechnicalTerm(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`"))
        guard trimmed.count >= 2 else { return false }
        if protectedTechnicalTerms.contains(normalizedKey(trimmed).replacingOccurrences(of: " ", with: "")) {
            return true
        }
        if trimmed.contains(".") || trimmed.contains("+") || trimmed.contains("#") { return true }
        // ALL CAPS acronym: OCR, API, SQL, GPU
        if trimmed.count >= 2 && trimmed.count <= 8 && trimmed.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return true
        }
        // CamelCase / PascalCase containing a lowercase→uppercase transition: SwiftUI, MySQL
        var previousWasLowercase = false
        for character in trimmed {
            if previousWasLowercase && character.isUppercase { return true }
            previousWasLowercase = character.isLowercase
        }
        return false
    }

    static let stopwords: Set<String> = [
        // English
        "the", "and", "for", "with", "that", "this", "from", "have", "has", "had", "are", "was",
        "were", "will", "would", "can", "could", "should", "you", "your", "our", "their", "them",
        "they", "there", "here", "what", "when", "where", "which", "who", "how", "why", "not",
        "but", "all", "any", "some", "more", "most", "other", "into", "over", "under", "about",
        "than", "then", "also", "such", "only", "just", "very", "much", "many", "each", "both",
        "use", "uses", "used", "using", "make", "makes", "made", "get", "gets", "got", "like",
        "see", "say", "says", "said", "one", "two", "new", "now", "out", "off", "own", "same",
        "it", "its", "is", "be", "as", "at", "by", "in", "on", "of", "or", "to", "do", "does",
        "did", "so", "if", "no", "up", "we", "an", "a", "i", "my", "me", "he", "she", "his",
        // Chinese function words
        "的", "了", "和", "是", "在", "有", "我", "也", "就", "不", "人", "都", "一", "一个",
        "上", "下", "中", "为", "以", "及", "与", "对", "从", "到", "把", "被", "让", "给",
        "这", "那", "这个", "那个", "什么", "怎么", "如何", "因为", "所以", "但是", "如果",
        "可以", "能够", "需要", "进行", "使用", "通过", "以及", "并且", "然后", "现在",
        "我们", "你们", "他们", "自己", "时候", "问题", "方法", "方式", "情况", "内容",
        "一些", "这些", "那些", "还有", "没有", "就是", "不是", "可以", "一样", "非常",
        "注意", "说明", "介绍", "如下", "以下", "上面", "下面", "其中", "由于", "为了"
    ]
}
