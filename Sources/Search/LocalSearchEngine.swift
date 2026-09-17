import Foundation

/// Hybrid vault search (spec §18–§22, §44).
///
/// `smart` fuses the lexical (BM25) and semantic (embedding) halves; `exact` uses the
/// lexical half alone. The user-facing vocabulary never mentions embeddings or vectors.
///
/// ## Adaptive fusion
/// The semantic half only contributes *new* results when it can actually tell notes apart.
/// Apple's system sentence embeddings place unrelated Chinese notes within a few points of
/// each other (measured: `数据库` 0.956 vs `iOS开发` 0.950 for a SwiftUI/OCR query), so
/// treating a 0.94 cosine as "relevant" would surface arbitrary notes. When the spread
/// across candidates is below `minimumSemanticMargin`, semantic similarity is kept only as a
/// re-ranking signal for rows the lexical half already matched. Dropping in a stronger
/// embedding provider immediately restores full semantic recall with no other change.
struct LocalSearchEngine {
    struct Weights: Equatable, Sendable {
        var semantic = 0.65
        var keyword = 0.30
        var recency = 0.05
    }

    /// Below this top-vs-runner-up lead the embedding is treated as non-discriminative.
    static let minimumSemanticMargin = 0.02
    /// Recency half-life-ish constant: score = exp(-ageInDays / decayDays).
    static let recencyDecayDays = 180.0

    let database: SearchDatabase
    let semanticIndex: SemanticSearchIndex
    let semanticEnabled: Bool
    var weights = Weights()
    var embeddingProvider: EmbeddingProviding = SystemEmbeddingProvider.shared
    var now: () -> Date = Date.init

    // MARK: - Entry point

    /// `expandedTerms` are model-suggested related keywords (China plan §25). They widen the
    /// lexical half without replacing the user's own terms.
    func search(query: String,
                mode: VaultSearchMode,
                expandedTerms: [String] = [],
                limit: Int = 40) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let keywordMatches = keywordCandidates(for: trimmed,
                                               expansions: expandedTerms,
                                               limit: limit * 3)
        guard mode == .smart, semanticEnabled, !semanticIndex.isEmpty else {
            return keywordOnlyResults(keywordMatches, limit: limit)
        }

        let semanticMatches = semanticCandidates(for: trimmed, limit: limit * 3)
        return fusedResults(keyword: keywordMatches, semantic: semanticMatches, limit: limit)
    }

    // MARK: - Keyword half

    private struct FileAggregate {
        var bestScore: Double
        var title: String
        var excerpt: String
        var modifiedAt: Date
        var matchedTerms: Set<String>
        var chunkID: String
        /// See `SearchResult.matchedQueryLiterally`.
        var literalMatch: Bool = true
    }

    private func keywordCandidates(for query: String,
                                   expansions: [String] = [],
                                   limit: Int) -> [String: FileAggregate] {
        guard let expression = KeywordSearchIndex.matchExpression(for: query,
                                                                  expansions: expansions)
        else { return [:] }
        let matches = database.keywordSearch(query: expression, limit: limit)
        let terms = KeywordSearchIndex.queryTerms(query)

        var aggregates: [String: FileAggregate] = [:]
        for match in matches {
            let matched = Set(KeywordSearchIndex.matchedTerms(in: match.title + " " + match.excerpt,
                                                              queryTerms: terms))
            let literal = Self.matchedLiterally(match,
                                                matched: matched,
                                                queryTerms: terms,
                                                expansionsRequested: !expansions.isEmpty,
                                                database: database)
            let score = match.score
            let metadata = database.chunkMetadata(chunkID: match.chunkID)
            if var existing = aggregates[match.filePath] {
                existing.matchedTerms.formUnion(matched)
                // Keep the excerpt from the strongest chunk.
                if score >= existing.bestScore {
                    existing.bestScore = score
                    existing.excerpt = match.excerpt
                    existing.chunkID = match.chunkID
                }
                existing.literalMatch = existing.literalMatch || literal
                aggregates[match.filePath] = existing
            } else {
                aggregates[match.filePath] = FileAggregate(bestScore: score,
                                                           title: metadata?.title ?? match.title,
                                                           excerpt: match.excerpt,
                                                           modifiedAt: metadata?.modifiedAt ?? .distantPast,
                                                           matchedTerms: matched,
                                                           chunkID: match.chunkID,
                                                           literalMatch: literal)
            }
        }
        return aggregates
    }

    /// A row is a *literal* match when one of the user's own terms occurs in it. The excerpt
    /// can miss a match that FTS found in the body or the path, so when expansions are in play
    /// the full chunk text is consulted — otherwise a real literal hit could be demoted below
    /// a suggestion. Nothing is re-read when there are no expansions.
    private static func matchedLiterally(_ match: KeywordMatch,
                                         matched: Set<String>,
                                         queryTerms: [String],
                                         expansionsRequested: Bool,
                                         database: SearchDatabase) -> Bool {
        guard expansionsRequested else { return true }
        if !matched.isEmpty { return true }
        guard let text = database.chunkText(chunkID: match.chunkID) else { return false }
        return !KeywordSearchIndex.matchedTerms(in: match.title + " " + text,
                                                queryTerms: queryTerms).isEmpty
    }

    private func keywordOnlyResults(_ aggregates: [String: FileAggregate], limit: Int) -> [SearchResult] {
        let maximum = aggregates.values.map(\.bestScore).max() ?? 0
        return aggregates
            .map { path, aggregate -> SearchResult in
                let keyword = maximum > 0 ? aggregate.bestScore / maximum : 0
                return makeResult(path: path,
                                  aggregate: aggregate,
                                  keyword: keyword,
                                  semantic: 0,
                                  semanticOnly: false)
            }
            .sorted(by: rankByLiteralFirst)
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Semantic half

    private struct SemanticAggregate {
        var bestSimilarity: Double
        var chunkID: String
        var title: String
        var modifiedAt: Date
        var filePath: String
    }

    private func semanticCandidates(for query: String, limit: Int) -> [String: SemanticAggregate] {
        // The query must be embedded in the same space as the stored vectors, so the spaces
        // to try come from the index itself rather than from a global capability list.
        var aggregates: [String: SemanticAggregate] = [:]
        for language in semanticIndex.languageCounts.keys.sorted() {
            guard let embedding = LocalEmbeddingService.embedding(for: query,
                                                                  language: language,
                                                                  provider: embeddingProvider)
            else { continue }
            let matches = semanticIndex.matches(queryVector: embedding.vector,
                                                language: language,
                                                limit: limit)
            for match in matches {
                let entry = match.entry
                if var existing = aggregates[entry.filePath] {
                    if match.similarity > existing.bestSimilarity {
                        existing.bestSimilarity = match.similarity
                        existing.chunkID = entry.chunkID
                        existing.title = entry.title
                        existing.modifiedAt = entry.modifiedAt
                    }
                    aggregates[entry.filePath] = existing
                } else {
                    aggregates[entry.filePath] = SemanticAggregate(bestSimilarity: match.similarity,
                                                                    chunkID: entry.chunkID,
                                                                    title: entry.title,
                                                                    modifiedAt: entry.modifiedAt,
                                                                    filePath: entry.filePath)
                }
            }
        }
        return aggregates
    }

    // MARK: - Fusion

    private func fusedResults(keyword: [String: FileAggregate],
                              semantic: [String: SemanticAggregate],
                              limit: Int) -> [SearchResult] {
        let similarities = semantic.values.map(\.bestSimilarity)
        let maximumSimilarity = similarities.max() ?? 0
        let minimumSimilarity = similarities.min() ?? 0
        // Top-vs-runner-up lead, not top-vs-field: the system embeddings compress every
        // Chinese note into a narrow high band, so the field range is mostly noise.
        let orderedSimilarities = similarities.sorted(by: >)
        let margin = orderedSimilarities.count >= 2
            ? orderedSimilarities[0] - orderedSimilarities[1]
            : 0
        let semanticIsDiscriminative = orderedSimilarities.count >= 2
            && margin >= Self.minimumSemanticMargin

        let maximumKeyword = keyword.values.map(\.bestScore).max() ?? 0
        let keywordWeight = weights.keyword
        let recencyWeight = weights.recency
        // Semantic-only rows are admitted only when the embedding can discriminate.
        let semanticWeight = semanticIsDiscriminative ? weights.semantic : 0
        let totalWeight = max(0.0001, semanticWeight + keywordWeight + recencyWeight)

        var merged: [String: SearchResult] = [:]
        let paths = Set(keyword.keys).union(semanticIsDiscriminative ? Set(semantic.keys) : [])

        for path in paths {
            let aggregate = keyword[path]
            let semanticAggregate = semantic[path]

            let keywordScore = aggregate.map { maximumKeyword > 0 ? $0.bestScore / maximumKeyword : 0 } ?? 0
            let rawSemantic = semanticAggregate?.bestSimilarity ?? 0
            let semanticScore = semanticIsDiscriminative
                ? max(0, (rawSemantic - minimumSimilarity) / max(0.0001, maximumSimilarity - minimumSimilarity))
                : 0
            let modifiedAt = aggregate?.modifiedAt ?? semanticAggregate?.modifiedAt ?? .distantPast
            let recencyScore = Self.recencyScore(modifiedAt: modifiedAt, now: now())

            let finalScore = (semanticScore * semanticWeight
                              + keywordScore * keywordWeight
                              + recencyScore * recencyWeight) / totalWeight

            var resolved = aggregate ?? FileAggregate(bestScore: 0,
                                                      title: semanticAggregate?.title ?? "",
                                                      excerpt: "",
                                                      modifiedAt: modifiedAt,
                                                      matchedTerms: [],
                                                      chunkID: semanticAggregate?.chunkID ?? "")
            if resolved.excerpt.isEmpty, let chunkID = semanticAggregate?.chunkID,
               let text = database.chunkText(chunkID: chunkID) {
                resolved.excerpt = Self.snippet(from: text)
            }

            let reason = Self.matchReason(matchedTerms: resolved.matchedTerms,
                                          semanticOnly: aggregate == nil,
                                          recencyScore: recencyScore)
            merged[path] = SearchResult(id: path,
                                        fileURL: URL(fileURLWithPath: path),
                                        title: resolved.title.isEmpty
                                            ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                                            : resolved.title,
                                        snippet: resolved.excerpt,
                                        matchReason: reason,
                                        score: finalScore,
                                        modifiedAt: modifiedAt,
                                        semanticScore: rawSemantic,
                                        keywordScore: keywordScore,
                                        recencyScore: recencyScore)
        }

        return merged.values.sorted(by: rankByLiteralFirst).prefix(limit).map { $0 }
    }

    private func makeResult(path: String,
                            aggregate: FileAggregate,
                            keyword: Double,
                            semantic: Double,
                            semanticOnly: Bool) -> SearchResult {
        let recency = Self.recencyScore(modifiedAt: aggregate.modifiedAt, now: now())
        let score = (keyword * weights.keyword + recency * weights.recency)
            / max(0.0001, weights.keyword + weights.recency)
        return SearchResult(id: path,
                            fileURL: URL(fileURLWithPath: path),
                            title: aggregate.title.isEmpty
                                ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                                : aggregate.title,
                            snippet: aggregate.excerpt,
                            matchReason: Self.matchReason(matchedTerms: aggregate.matchedTerms,
                                                          semanticOnly: semanticOnly,
                                                          recencyScore: recency),
                            score: score,
                            modifiedAt: aggregate.modifiedAt,
                            semanticScore: semantic,
                            keywordScore: keyword,
                            recencyScore: recency,
                            matchedQueryLiterally: aggregate.literalMatch)
    }

    private func rank(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedAscending
    }

    /// §25: a literal match is always better than a model-suggested one, no matter how strong
    /// the suggestion scored. Without expansions every row is literal, so this is a no-op.
    private func rankByLiteralFirst(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.matchedQueryLiterally != rhs.matchedQueryLiterally {
            return lhs.matchedQueryLiterally
        }
        return rank(lhs, rhs)
    }

    private static func recencyScore(modifiedAt: Date, now: Date) -> Double {
        guard modifiedAt != .distantPast else { return 0 }
        let ageInDays = max(0, now.timeIntervalSince(modifiedAt)) / 86_400
        return exp(-ageInDays / recencyDecayDays)
    }

    private static func matchReason(matchedTerms: Set<String>,
                                    semanticOnly: Bool,
                                    recencyScore: Double) -> String {
        if semanticOnly {
            return String(localized: "Related by meaning")
        }
        if matchedTerms.isEmpty {
            return String(localized: "Content match")
        }
        let listed = matchedTerms.prefix(3).joined(separator: String(localized: "、"))
        return String(localized: "Matches “\(listed)”")
    }

    /// A short window around the start of a chunk, used when a result has no stored excerpt.
    private static func snippet(from text: String, limit: Int = 200) -> String {
        let flattened = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > limit ? String(flattened.prefix(limit)) : flattened
    }
}
