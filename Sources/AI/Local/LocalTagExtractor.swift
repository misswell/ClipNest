import Foundation

/// Local tag extraction: frequency + technical-term protection, never a generative guess.
struct LocalTagExtractor {
    var minimumTags = 2
    var maximumTags = 6
    /// A candidate must be at least this distinctive to become a tag.
    var minimumScore = 1.2

    func tags(in text: String, title: String = "", limit: Int? = nil) -> [String] {
        let cap = max(minimumTags, min(limit ?? maximumTags, maximumTags))
        // Word terms, not `terms`: the latter carries overlapping CJK bi-grams added for
        // search recall, which produced tags like `片文` cut out of `图片文字识别`.
        let terms = LocalTextAnalyzer.wordTerms(in: text, limit: 40)
        guard !terms.isEmpty else { return titleTags(from: title, limit: cap) }

        let titleKeys = Set(LocalTextAnalyzer.tokens(in: title).map(LocalTextAnalyzer.normalizedKey))
        var output: [String] = []
        var seenKeys = Set<String>()

        func append(_ term: LocalTextAnalyzer.Term) {
            guard seenKeys.insert(term.key).inserted else { return }
            output.append(term.text)
        }

        // Terms already in the title are what the note is *about* — take them first.
        for term in terms where titleKeys.contains(term.key) && output.count < cap {
            append(term)
        }
        for term in terms where output.count < cap {
            let score = LocalTextAnalyzer.score(count: term.count, technical: term.isTechnical, key: term.key)
            guard score >= minimumScore || term.isTechnical else { continue }
            append(term)
        }

        if output.count < minimumTags {
            for term in terms where output.count < minimumTags {
                append(term)
            }
        }
        return Array(output.prefix(cap))
    }

    private func titleTags(from title: String, limit: Int) -> [String] {
        LocalTextAnalyzer.wordTerms(in: title, limit: limit)
            .filter { LocalTextAnalyzer.score(count: $0.count, technical: $0.isTechnical, key: $0.key) >= minimumScore || $0.isTechnical }
            .map(\.text)
            .prefix(limit)
            .map { $0 }
    }
}
