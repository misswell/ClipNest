import Foundation
import Accelerate

/// In-memory vector layer (spec §23, §39).
///
/// Only embeddings and the metadata needed to render a row are held; note bodies stay in
/// SQLite until a result is actually shown. Cosine similarity is computed with Accelerate,
/// which comfortably handles the few thousand to few tens of thousands of chunks a personal
/// vault produces. A graph index (HNSW) only becomes interesting far beyond that.
struct SemanticSearchIndex {
    struct Entry: Equatable, Sendable {
        let chunkID: String
        let filePath: String
        let title: String
        let modifiedAt: Date
        let language: String
        /// Unit-length vector, so similarity is a single dot product.
        let unitVector: [Float]
        let dimension: Int
    }

    private(set) var entries: [Entry] = []
    /// Chunk counts per file, so a file with more matching chunks can be recognised.
    private(set) var languageCounts: [String: Int] = [:]

    var isEmpty: Bool { entries.isEmpty }

    init(embeddings: [StoredEmbedding] = []) {
        entries = embeddings.compactMap(Self.makeEntry)
        languageCounts = entries.reduce(into: [:]) { result, entry in
            result[entry.language, default: 0] += 1
        }
    }

    private static func makeEntry(_ stored: StoredEmbedding) -> Entry? {
        guard !stored.vector.isEmpty else { return nil }
        var norm: Float = 0
        vDSP_svesq(stored.vector, 1, &norm, vDSP_Length(stored.vector.count))
        guard norm > 0 else { return nil }
        let scale = 1 / norm.squareRoot()
        var unit = [Float](repeating: 0, count: stored.vector.count)
        var divisor = norm.squareRoot()
        vDSP_vsdiv(stored.vector, 1, &divisor, &unit, 1, vDSP_Length(stored.vector.count))
        _ = scale
        return Entry(chunkID: stored.chunkID,
                     filePath: stored.filePath,
                     title: stored.title,
                     modifiedAt: stored.modifiedAt,
                     language: stored.language,
                     unitVector: unit,
                     dimension: unit.count)
    }

    /// Cosine similarity against every entry in the query's embedding space.
    func matches(queryVector: [Float], language: String, limit: Int) -> [(entry: Entry, similarity: Double)] {
        guard !queryVector.isEmpty else { return [] }
        var queryNorm: Float = 0
        vDSP_svesq(queryVector, 1, &queryNorm, vDSP_Length(queryVector.count))
        guard queryNorm > 0 else { return [] }
        var queryUnit = [Float](repeating: 0, count: queryVector.count)
        var divisor = queryNorm.squareRoot()
        vDSP_vsdiv(queryVector, 1, &divisor, &queryUnit, 1, vDSP_Length(queryVector.count))

        var scored: [(entry: Entry, similarity: Double)] = []
        scored.reserveCapacity(entries.count)
        for entry in entries where entry.language == language && entry.dimension == queryUnit.count {
            var dot: Float = 0
            vDSP_dotpr(queryUnit, 1, entry.unitVector, 1, &dot, vDSP_Length(queryUnit.count))
            scored.append((entry, Double(dot)))
        }
        scored.sort { lhs, rhs in
            if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
            return lhs.entry.chunkID < rhs.entry.chunkID
        }
        return Array(scored.prefix(max(0, limit)))
    }
}
