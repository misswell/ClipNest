import Foundation
import NaturalLanguage

/// A vector plus the embedding space it belongs to. Vectors from different languages have
/// different dimensions (Chinese 640, English 512 on Apple's system models) and must never
/// be compared directly.
struct LocalEmbedding: Equatable {
    let vector: [Float]
    let language: String

    var dimension: Int { vector.count }
}

/// Swap point for the optional enhanced model (spec §24): a Core ML `gte-small-zh` INT8
/// bundle can conform here and every call site keeps working unchanged.
protocol EmbeddingProviding: AnyObject {
    func vector(for text: String, language: String) -> [Float]?
    func dimension(for language: String) -> Int?
}

/// Apple's built-in sentence embeddings. The `NLEmbedding` instances are process-wide and
/// not documented as thread-safe, so every lookup is guarded by a lock and shared instead
/// of being re-created per task.
///
/// Embedding is the most expensive operation in the local pipeline (tens of milliseconds per
/// call), and category profiles are re-embedded on every classification, so vectors are
/// memoised. The cache is bounded and cleared wholesale once it grows past `cacheLimit`,
/// which keeps steady-state memory flat without an LRU's bookkeeping.
final class SystemEmbeddingProvider: EmbeddingProviding {
    static let shared = SystemEmbeddingProvider()

    /// Roughly a few hundred KB of floats; comfortably above the working set of a
    /// classification round (profiles + a handful of notes) and of one search query.
    static let cacheLimit = 512

    private let lock = NSLock()
    private var sentenceEmbeddings: [String: NLEmbedding] = [:]
    private var missingLanguages: Set<String> = []
    private var vectorCache: [String: [Float]] = [:]
    private var knownMisses: Set<String> = []
    private var cacheHits = 0
    private var cacheMisses = 0

    private init() {}

    func embedding(for language: String) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = sentenceEmbeddings[language] { return cached }
        if missingLanguages.contains(language) { return nil }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language)) else {
            missingLanguages.insert(language)
            return nil
        }
        sentenceEmbeddings[language] = embedding
        return embedding
    }

    private func cacheKey(_ text: String, _ language: String) -> String {
        "\(language)\u{1}\(text)"
    }

    func vector(for text: String, language: String) -> [Float]? {
        let key = cacheKey(text, language)

        lock.lock()
        if let cached = vectorCache[key] {
            cacheHits += 1
            lock.unlock()
            return cached
        }
        if knownMisses.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let embedding = embedding(for: language),
              let vector = embedding.vector(for: text)
        else {
            lock.lock()
            knownMisses.insert(key)
            lock.unlock()
            return nil
        }

        let floats = vector.map(Float.init)
        lock.lock()
        if vectorCache.count >= Self.cacheLimit {
            vectorCache.removeAll(keepingCapacity: true)
            knownMisses.removeAll(keepingCapacity: true)
        }
        vectorCache[key] = floats
        cacheMisses += 1
        lock.unlock()
        return floats
    }

    func dimension(for language: String) -> Int? {
        embedding(for: language)?.dimension
    }

    /// Diagnostics for the settings screen and the benchmark report.
    var cacheStatistics: (hits: Int, misses: Int, entries: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (cacheHits, cacheMisses, vectorCache.count)
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        vectorCache.removeAll(keepingCapacity: true)
        knownMisses.removeAll(keepingCapacity: true)
        cacheHits = 0
        cacheMisses = 0
    }
}

/// Local semantic primitives backed by Apple Natural Language.
///
/// Benchmark note: on the system embeddings `SwiftUI`, `Vision`, `OCR`, `Xcode` and most
/// other technical tokens are out-of-vocabulary, and unrelated Chinese sentences sit within
/// a few points of each other. This layer is therefore treated as a *supporting* signal —
/// the lexical layer in `LocalTextAnalyzer` carries the accuracy, and `LocalSemanticScorer`
/// only trusts the embedding when it is actually discriminative.
enum LocalEmbeddingService {
    static let chineseLanguage = "zh-Hans"
    static let englishLanguage = "en"

    /// Languages the current device can embed. Empty when the assets are missing.
    static func supportedLanguages() -> [String] {
        [chineseLanguage, englishLanguage].filter {
            SystemEmbeddingProvider.shared.dimension(for: $0) != nil
        }
    }

    static func isAvailable(_ language: String) -> Bool {
        SystemEmbeddingProvider.shared.dimension(for: language) != nil
    }

    /// Embedding in the text's dominant language space, or nil when unavailable.
    static func embedding(for text: String,
                          provider: EmbeddingProviding = SystemEmbeddingProvider.shared) -> LocalEmbedding? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let profile = LocalLanguageProfile.analyze(trimmed)
        guard let language = profile.embeddingLanguage else { return nil }
        guard let vector = provider.vector(for: trimmed, language: language) else { return nil }
        return LocalEmbedding(vector: vector, language: language)
    }

    /// Embedding in one explicit language space (used to score mixed content twice).
    static func embedding(for text: String,
                          language: String,
                          provider: EmbeddingProviding = SystemEmbeddingProvider.shared) -> LocalEmbedding? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let vector = provider.vector(for: trimmed, language: language) else { return nil }
        return LocalEmbedding(vector: vector, language: language)
    }

    /// Cosine similarity in [-1, 1]. Returns 0 for mismatched or empty vectors.
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in 0..<lhs.count {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }
}
