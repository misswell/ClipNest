import Foundation

/// Extractive summarization: pick the best 1–3 existing sentences, in their original
/// order. Nothing is paraphrased and nothing is invented, which is the whole point of a
/// summary that a local, non-generative engine can be trusted to produce.
struct LocalSummarizer {
    /// Sentence-count bounds for the produced summary.
    var minimumSentences = 1
    var maximumSentences = 3

    /// Spec §12 weights, kept as tunable constants so a benchmark can move them.
    var keywordWeight = 0.45
    var positionWeight = 0.20
    var lengthWeight = 0.15
    var titleSimilarityWeight = 0.20

    func summarize(_ text: String, title: String = "") -> String {
        let sentences = LocalTextAnalyzer.sentences(in: text, minimumLength: 6)
        guard !sentences.isEmpty else {
            // Nothing looked like a sentence (a title, a single word, a list). Echoing a
            // short input verbatim is still a truthful summary; a long one gets none.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count <= 200 ? trimmed : ""
        }
        guard sentences.count > minimumSentences else { return sentences.joined(separator: " ") }

        let keywordScores = LocalTextAnalyzer.terms(in: text, limit: 32)
        let keywordWeights = Dictionary(uniqueKeysWithValues: keywordScores.map { ($0.key, LocalTextAnalyzer.score(count: $0.count, technical: $0.isTechnical, key: $0.key)) })
        let maximumKeywordWeight = keywordWeights.values.max() ?? 1

        let titleKeys = Set(LocalTextAnalyzer.tokens(in: title).map(LocalTextAnalyzer.normalizedKey))

        let scored = sentences.enumerated().map { index, sentence -> (index: Int, sentence: String, score: Double) in
            let score =
                keywordScore(sentence, weights: keywordWeights, maximum: maximumKeywordWeight) * keywordWeight
                + positionScore(index: index, total: sentences.count) * positionWeight
                + lengthScore(sentence) * lengthWeight
                + similarityScore(sentence, titleKeys: titleKeys) * titleSimilarityWeight
            return (index, sentence, score)
        }

        let target = targetSentenceCount(for: text, available: sentences.count)
        let chosen = scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .prefix(target)
            .sorted { $0.index < $1.index }

        return chosen.map(\.sentence).joined(separator: " ")
    }

    /// Longer inputs earn a longer summary, capped by `maximumSentences`.
    private func targetSentenceCount(for text: String, available: Int) -> Int {
        let length = text.count
        let desired: Int
        switch length {
        case ..<220: desired = 1
        case ..<900: desired = 2
        default: desired = 3
        }
        return max(minimumSentences, min(desired, max(minimumSentences, min(maximumSentences, available))))
    }

    private func keywordScore(_ sentence: String,
                              weights: [String: Double],
                              maximum: Double) -> Double {
        guard maximum > 0 else { return 0 }
        var total = 0.0
        var seen = Set<String>()
        for token in LocalTextAnalyzer.tokens(in: sentence) {
            let key = LocalTextAnalyzer.normalizedKey(token)
            guard seen.insert(key).inserted, let weight = weights[key] else { continue }
            total += weight
        }
        // Normalize by sentence length so a long sentence does not win on volume alone.
        let lengthPenalty = Double(max(1, LocalTextAnalyzer.tokens(in: sentence).count))
        return min(1, total / maximum / max(1, lengthPenalty / 12))
    }

    /// Earlier sentences carry the lede; the very first gets the full bonus.
    private func positionScore(index: Int, total: Int) -> Double {
        guard total > 1 else { return 1 }
        return 1 - (Double(index) / Double(total - 1)) * 0.7
    }

    /// Prefer informative sentences: 20–160 characters in the dominant script.
    private func lengthScore(_ sentence: String) -> Double {
        let count = sentence.count
        switch count {
        case 0..<12: return 0.1
        case 12..<30: return 0.6
        case 30...170: return 1.0
        case 171...320: return 0.7
        default: return 0.4
        }
    }

    private func similarityScore(_ sentence: String, titleKeys: Set<String>) -> Double {
        guard !titleKeys.isEmpty else { return 0.5 }
        let keys = Set(LocalTextAnalyzer.tokens(in: sentence).map(LocalTextAnalyzer.normalizedKey))
        guard !keys.isEmpty else { return 0 }
        let overlap = keys.intersection(titleKeys).count
        return min(1, Double(overlap) / Double(max(1, titleKeys.count)))
    }
}
