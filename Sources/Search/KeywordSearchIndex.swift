import Foundation

/// Builds and queries the lexical half of the search index (spec §19).
///
/// Both sides run through `LocalTextAnalyzer`, which emits CJK bi-grams. That is what makes
/// FTS5 work for Chinese at all: the index stores `"如何 使用 swiftui 调用 vision ocr 识别"`,
/// and a query for `图片文字识别` becomes a MATCH expression over the same bi-gram
/// vocabulary. Mixed Chinese/English notes therefore match on either script.
enum KeywordSearchIndex {
    /// FTS5 document fields, in the column order declared by `SearchDatabase`.
    struct Fields {
        let title: String
        let tags: String
        let summary: String
        let fileName: String
        let body: String
        let path: String

        var ordered: [String] { [title, tags, summary, fileName, body, path] }
    }

    static func fields(for document: SearchDocument,
                       bodyText: String,
                       vaultRoot: URL?) -> Fields {
        Fields(title: terms(document.title),
               tags: terms(document.tags.joined(separator: " ")),
               summary: terms(document.summary),
               fileName: terms(document.fileName),
               body: terms(bodyText.isEmpty ? document.body : bodyText),
               path: terms(relativePath(document.fileURL, root: vaultRoot)))
    }

    /// Tokenizes text into a space-separated term string for the FTS index.
    static func terms(_ text: String) -> String {
        var seen = Set<String>()
        var output: [String] = []
        for token in LocalTextAnalyzer.tokens(in: text) {
            let key = LocalTextAnalyzer.normalizedKey(token)
            guard !key.isEmpty, !LocalTextAnalyzer.stopwords.contains(key) else { continue }
            guard seen.insert(key).inserted else { continue }
            output.append(key)
        }
        return output.joined(separator: " ")
    }

    /// The query-side vocabulary: same tokenizer, same bi-grams, plus the raw lowercased
    /// query so an exact substring the analyzer drops still matches.
    ///
    /// A one-character CJK token is dropped, mirroring the two-character floor `terms()`
    /// applies on the indexing side. The system tokenizer splits `截图取字` into
    /// `截图 / 取 / 字`, and such a character can never occur in the index — but it *would*
    /// be reported as a matched term by the highlight check, which is how a query for
    /// 截图取字 came to claim a literal match on a note that only contains 字. A query that
    /// really is one CJK character still works, through the collapsed whole-query term below.
    static func queryTerms(_ userQuery: String) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        func append(_ key: String) {
            guard !key.isEmpty, !LocalTextAnalyzer.stopwords.contains(key) else { return }
            guard seen.insert(key).inserted else { return }
            output.append(key)
        }
        for token in LocalTextAnalyzer.tokens(in: userQuery) {
            let key = LocalTextAnalyzer.normalizedKey(token)
            if key.count < 2, let first = key.unicodeScalars.first,
               LocalLanguageProfile.isCJK(first) {
                continue
            }
            append(key)
        }
        let collapsed = LocalTextAnalyzer.normalizedKey(userQuery)
        if collapsed.contains(" ") == false { append(collapsed) }
        return output
    }

    /// Builds a safe FTS5 MATCH expression. Every term is quoted, so no user input can be
    /// interpreted as FTS syntax (`-`, `*`, `:`, `^`, unbalanced quotes).
    ///
    /// The last Latin term is turned into a prefix query (spec §19), because search runs as
    /// the user types: `swift` should already have found `SwiftUI` before the word is
    /// finished. Chinese terms are already character bi-grams — prefixing those would match
    /// almost everything, so they stay exact.
    ///
    /// `expansions` are the model-suggested related keywords (China plan §25). They are OR'd in
    /// *after* the user's own terms, and only the user's last Latin term gets the prefix
    /// treatment, so the literal query keeps its advantage.
    static func matchExpression(for userQuery: String, expansions: [String] = []) -> String? {
        let terms = queryTerms(userQuery)
        let extra = expansionTerms(expansions, excluding: terms)
        guard !terms.isEmpty || !extra.isEmpty else { return nil }

        var clauses = terms.enumerated().map { index, term -> String in
            let quoted = quote(term)
            guard index == terms.count - 1, isPrefixable(term) else { return quoted }
            return quoted + "*"
        }
        clauses.append(contentsOf: extra.map(quote))
        return clauses.joined(separator: " OR ")
    }

    /// Expansion keywords, analysed with the same tokenizer as the index so a suggested
    /// Chinese phrase becomes the bi-grams the index actually stores.
    static func expansionTerms(_ expansions: [String], excluding existing: [String]) -> [String] {
        var seen = Set(existing)
        var output: [String] = []
        for expansion in expansions {
            for term in queryTerms(expansion) where seen.insert(term).inserted {
                output.append(term)
            }
        }
        return output
    }

    private static func quote(_ term: String) -> String {
        "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Latin, multi-character terms are worth matching as prefixes; CJK bi-grams are not.
    private static func isPrefixable(_ term: String) -> Bool {
        guard term.count >= 3 else { return false }
        guard let first = term.unicodeScalars.first else { return false }
        return !LocalLanguageProfile.isCJK(first)
    }

    /// Which of the user's terms actually occur in a chunk — used for the "why did this
    /// match" line in the results list.
    static func matchedTerms(in text: String, queryTerms: [String]) -> [String] {
        guard !queryTerms.isEmpty else { return [] }
        let haystack = LocalTextAnalyzer.normalizedKey(text)
        let tokens = Set(LocalTextAnalyzer.tokens(in: text).map(LocalTextAnalyzer.normalizedKey))
        return queryTerms.filter { term in
            tokens.contains(term) || haystack.contains(term)
        }
    }

    static func relativePath(_ url: URL, root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
