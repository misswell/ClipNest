import Foundation

/// A category's semantic fingerprint: its name is far too little to embed on its own, so
/// the profile also carries curated keywords and the titles of notes the category already
/// holds (spec §15).
struct CategoryProfile: Equatable, Sendable {
    let name: String
    let keywords: [String]
    let noteTitles: [String]

    init(name: String, keywords: [String] = [], noteTitles: [String] = []) {
        self.name = name
        self.keywords = keywords
        self.noteTitles = noteTitles
    }

    /// Text handed to the embedding model. The name is repeated so it keeps weight against
    /// a long list of note titles.
    var profileText: String {
        var parts = [name, name]
        parts.append(contentsOf: keywords)
        parts.append(contentsOf: noteTitles)
        return parts.joined(separator: " ")
    }

    /// Distinctive lexical keys.
    ///
    /// Chinese is matched without a dictionary, so a keyword has to be reachable as a
    /// substring of arbitrary note text: `提示词` in the profile must still match
    /// `大语言模型的提示词工程与` in a note. Every Chinese token is therefore expanded into
    /// its character bi-grams as well as being kept whole, mirroring what
    /// `LocalTextAnalyzer.scriptRuns` does to the note side.
    var distinctiveKeys: Set<String> {
        var text = name + " " + keywords.joined(separator: " ") + " " + noteTitles.joined(separator: " ")
        text = LocalTextAnalyzer.cleanInline(text)
        var keys = Set<String>()
        for token in LocalTextAnalyzer.tokens(in: text) {
            let key = LocalTextAnalyzer.normalizedKey(token)
            guard !key.isEmpty, !LocalTextAnalyzer.stopwords.contains(key) else { continue }
            keys.insert(key)
            guard key.count > 2,
                  let first = key.unicodeScalars.first,
                  LocalLanguageProfile.isCJK(first)
            else { continue }
            let characters = Array(key)
            for index in 0..<(characters.count - 1) {
                keys.insert(String(characters[index...index + 1]))
            }
        }
        return keys
    }
}

struct LocalClassificationCandidate: Equatable {
    let category: String
    /// Raw embedding similarity (0 when no embedding was usable).
    let semanticScore: Double
    /// Lexical overlap with the profile in 0...1.
    let keywordScore: Double
    /// Blended score the thresholds are applied to.
    let score: Double
}

struct LocalClassificationResult: Equatable {
    /// The category to use. nil means "leave it in Inbox": either the evidence was too weak
    /// (`score < candidate`) or merely moderate (`candidate <= score < autoAssign`), and
    /// spec §16 is explicit that a low-confidence guess must never be forced. A moderate
    /// match is still reported through `suggestedCategory`.
    let category: String?
    /// The best category when it cleared `candidate` but not `autoAssign`.
    let suggestedCategory: String?
    let score: Double
    let candidates: [LocalClassificationCandidate]
    /// False when the embedding could not tell the categories apart and was given no vote.
    let usedEmbedding: Bool

    static let empty = LocalClassificationResult(category: nil,
                                                 suggestedCategory: nil,
                                                 score: 0,
                                                 candidates: [],
                                                 usedEmbedding: false)
}

/// Local semantic classification.
///
/// ## Why the blend is adaptive
/// Apple's system sentence embeddings put every Chinese sentence within a few points of
/// every other one (`数据库` scored 0.956 against a SwiftUI/OCR note while `iOS开发` scored
/// 0.950), and technical tokens like `SwiftUI`, `Vision` and `OCR` are out of vocabulary
/// entirely. Feeding those raw cosines into a fixed threshold would either assign nothing
/// or assign wrongly.
///
/// So the embedding is measured for *discrimination* first: it only receives its 0.7 vote
/// when the top candidate is meaningfully separated from the field. When it is not, the
/// lexical layer votes alone — and when a better embedding model (the optional Core ML
/// `gte-small-zh` of spec §24) is dropped in behind `EmbeddingProviding`, it earns its
/// weight automatically.
struct LocalSemanticClassifier {
    struct Thresholds: Equatable, Sendable {
        /// At or above this blended score the category is assigned automatically.
        var autoAssign = 0.72
        /// Between `candidate` and `autoAssign` there is a plausible match but weak evidence.
        var candidate = 0.58
        /// How far ahead of the runner-up the best candidate must be before the embedding is
        /// allowed to vote.
        ///
        /// Deliberately the top-vs-*second* lead rather than top-vs-*field*: Apple's system
        /// embeddings put every Chinese technical note within a 0.90–0.97 band, so the
        /// top-to-bottom range looks wide while the top two candidates are effectively tied.
        /// Measured on the benchmark vault, a top-vs-field spread of 0.06 corresponds to a
        /// top-vs-second lead of 0.003 — pure noise. Requiring a real lead is what keeps a
        /// model that cannot discriminate from outvoting the lexical layer.
        var minimumSemanticMargin = 0.02
        /// An unambiguous semantic winner may be assigned on the embedding alone even though
        /// the blend cannot reach `autoAssign`: a purely semantic match contributes
        /// `semanticWeight` (0.7) and no lexical weight, so it caps out just under the 0.72
        /// bar. Requiring near-total separation of the winner keeps that escape hatch safe —
        /// this is where a genuinely good embedding model (spec §24) earns its keep.
        var unambiguousSemanticConfidence = 0.9

        static let `default` = Thresholds()
    }

    var thresholds: Thresholds = .default
    var semanticWeight = 0.7
    var keywordWeight = 0.3
    var embeddingProvider: EmbeddingProviding = SystemEmbeddingProvider.shared

    /// Assigns only when confident; an empty result means "leave it in Inbox".
    func classify(text: String, categories: [CategoryProfile]) -> LocalClassificationResult {
        let profiles = categories.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !profiles.isEmpty else { return .empty }

        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return .empty }

        let semantics = semanticScores(note: note, profiles: profiles)
        let keywords = keywordScores(note: note, profiles: profiles)

        let maximumSemantic = semantics.values.max() ?? 0
        let minimumSemantic = semantics.values.min() ?? 0
        // The embedding earns a vote only when the winner clearly beats the runner-up.
        let orderedSemantics = semantics.values.sorted(by: >)
        let margin = orderedSemantics.count >= 2 ? orderedSemantics[0] - orderedSemantics[1] : 0
        let discriminative = orderedSemantics.count >= 2
            && margin >= thresholds.minimumSemanticMargin

        let effectiveSemanticWeight = discriminative ? semanticWeight : 0
        let effectiveKeywordWeight = discriminative ? keywordWeight : 1.0
        let totalWeight = effectiveSemanticWeight + effectiveKeywordWeight

        var candidates: [LocalClassificationCandidate] = []
        var bestSemanticConfidence = 0.0
        for profile in profiles {
            let semantic = semantics[profile.name] ?? 0
            let keyword = keywords[profile.name] ?? 0
            let rawSemantic = discriminative
                ? calibratedSemanticConfidence(maximum: maximumSemantic,
                                               minimum: minimumSemantic,
                                               value: semantic)
                : 0
            let score = totalWeight > 0
                ? (rawSemantic * effectiveSemanticWeight + keyword * effectiveKeywordWeight) / totalWeight
                : 0
            bestSemanticConfidence = max(bestSemanticConfidence, rawSemantic)
            candidates.append(LocalClassificationCandidate(category: profile.name,
                                                           semanticScore: semantic,
                                                           keywordScore: keyword,
                                                           score: score))
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
        }

        guard let best = candidates.first else { return .empty }

        // Three bands (spec §16): assign, suggest, or say nothing.
        let clearsAutoAssign = best.score >= thresholds.autoAssign
            || (discriminative && bestSemanticConfidence >= thresholds.unambiguousSemanticConfidence
                && best.score >= thresholds.candidate)
        let clearsCandidate = best.score >= thresholds.candidate
        return LocalClassificationResult(
            category: clearsAutoAssign ? best.category : nil,
            suggestedCategory: (!clearsAutoAssign && clearsCandidate) ? best.category : nil,
            score: best.score,
            candidates: candidates,
            usedEmbedding: discriminative)
    }

    /// How far above the field the winner sits, normalized by the headroom that is left.
    /// A winner that is only level with the pack scores 0 no matter how high its cosine is.
    private func calibratedSemanticConfidence(maximum: Double, minimum: Double, value: Double) -> Double {
        let headroom = max(0.0001, 1 - minimum)
        let confidence = (value - minimum) / headroom
        return min(1, max(0, confidence))
    }

    // MARK: - Semantic layer

    private func semanticScores(note: String, profiles: [CategoryProfile]) -> [String: Double] {
        let profile = LocalLanguageProfile.analyze(note)
        let languages: [String]
        switch profile.script {
        case .mixed:
            // Score in both spaces and keep the better one per candidate: a mixed note
            // genuinely belongs to whichever space recognises it.
            languages = LocalEmbeddingService.supportedLanguages()
        case .chinese:
            languages = [LocalEmbeddingService.chineseLanguage]
        case .english:
            languages = [LocalEmbeddingService.englishLanguage]
        case .other:
            languages = LocalEmbeddingService.supportedLanguages()
        }

        var best: [String: Double] = [:]
        for language in languages {
            guard let noteEmbedding = LocalEmbeddingService.embedding(for: note,
                                                                      language: language,
                                                                      provider: embeddingProvider)
            else { continue }
            for category in profiles {
                guard let categoryEmbedding = LocalEmbeddingService.embedding(
                    for: category.profileText,
                    language: language,
                    provider: embeddingProvider
                ) else { continue }
                let similarity = Double(LocalEmbeddingService.cosineSimilarity(noteEmbedding.vector,
                                                                               categoryEmbedding.vector))
                best[category.name] = max(best[category.name] ?? -.greatestFiniteMagnitude, similarity)
            }
        }
        return best
    }

    // MARK: - Lexical layer

    /// "Of the note's words that mean something to the category system, how much belongs to
    /// this category?"
    ///
    /// The denominator is deliberately restricted to the union of all profile vocabularies
    /// rather than every token in the note. Chinese produced without a dictionary yields a
    /// lot of meaningless bi-grams (`的索`, `询优`), and counting them as "unmatched" would
    /// drag every genuine match below the threshold. Words outside the category vocabulary
    /// carry no information about *which* category fits, so they are excluded from both
    /// sides of the ratio. A note that shares nothing with any profile scores 0 and stays in
    /// Inbox; a note whose evidence is split between two categories also scores low, which is
    /// exactly the "don't force a low-confidence classification" behaviour we want.
    private func keywordScores(note: String, profiles: [CategoryProfile]) -> [String: Double] {
        let terms = LocalTextAnalyzer.terms(in: note, limit: 60)
        let vocabulary = profiles.reduce(into: Set<String>()) { result, profile in
            result.formUnion(profile.distinctiveKeys)
        }

        var termWeights: [String: Double] = [:]
        for term in terms {
            termWeights[term.key] = LocalTextAnalyzer.score(count: term.count,
                                                            technical: term.isTechnical,
                                                            key: term.key)
        }
        let relevant = termWeights.filter { vocabulary.contains($0.key) }
        let denominator = relevant.values.reduce(0, +)

        let noteTokens = Set(terms.map(\.key))
        var output: [String: Double] = [:]
        for profile in profiles {
            let keys = profile.distinctiveKeys
            guard !keys.isEmpty else {
                output[profile.name] = 0
                continue
            }
            var score = 0.0
            if denominator > 0 {
                let matchedWeight = relevant
                    .filter { keys.contains($0.key) }
                    .values
                    .reduce(0, +)
                score = matchedWeight / denominator
            }
            if matchesCategoryName(noteTokens: noteTokens, name: profile.name) {
                score = max(score, 0.95)
            }
            output[profile.name] = min(1, score)
        }
        return output
    }

    private func matchesCategoryName(noteTokens: Set<String>, name: String) -> Bool {
        let nameKeys = LocalTextAnalyzer.tokens(in: name)
            .map(LocalTextAnalyzer.normalizedKey)
            .filter { !$0.isEmpty && !LocalTextAnalyzer.stopwords.contains($0) }
        guard !nameKeys.isEmpty else { return false }
        return nameKeys.allSatisfy { noteTokens.contains($0) }
    }
}
