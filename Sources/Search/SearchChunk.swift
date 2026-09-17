import Foundation

/// One indexed fragment of a note. Notes are never embedded whole (spec §20): they are cut
/// on Markdown structure at 300–600 Chinese characters / 200–400 tokens.
struct SearchChunk: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let title: String
    let text: String
    let embedding: [Float]
    /// Embedding space the vector belongs to; vectors from different spaces cannot be compared.
    let embeddingLanguage: String
    let modifiedAt: Date

    init(id: UUID = UUID(),
         fileURL: URL,
         title: String,
         text: String,
         embedding: [Float] = [],
         embeddingLanguage: String = "",
         modifiedAt: Date) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.text = text
        self.embedding = embedding
        self.embeddingLanguage = embeddingLanguage
        self.modifiedAt = modifiedAt
    }
}

/// What a search returns: enough to render a row without reading the note.
struct SearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let fileURL: URL
    let title: String
    let snippet: String
    /// Human-readable explanation of why this row matched (spec §21).
    let matchReason: String
    let score: Double
    let modifiedAt: Date

    /// Component scores, kept for tests and for a future ranking-debug surface.
    let semanticScore: Double
    let keywordScore: Double
    let recencyScore: Double

    /// True when one of the *user's own* query terms matched, as opposed to a keyword the
    /// on-device model suggested (China plan §25). Literal matches are a rank tier above
    /// expansion-only ones, so a suggestion can add results but never displace the note the
    /// user actually asked for.
    var matchedQueryLiterally: Bool = true
}

/// A chunk ready for persistence: display text, its embedding, and the tokenized field
/// strings the FTS5 table indexes.
struct IndexedChunk: Equatable, Sendable {
    let id: String
    let title: String
    let text: String
    let excerpt: String
    let language: String
    let embedding: [Float]
    let modifiedAt: Date
    /// Tokenized FTS columns, in table order: title, tags, summary, filename, body, path.
    let ftsFields: [String]
}

/// A note prepared for indexing: the pieces the keyword index needs separately, plus the
/// body that gets chunked.
struct SearchDocument: Equatable, Sendable {
    let fileURL: URL
    let title: String
    let tags: [String]
    let summary: String
    let body: String
    let modifiedAt: Date

    var fileName: String { fileURL.deletingPathExtension().lastPathComponent }

    /// Everything a chunk-level keyword index should be able to match on.
    var searchableText: String {
        ([title, summary] + tags + [body]).joined(separator: "\n")
    }

    /// Parses the subset of Markdown/YAML the index needs. Unknown frontmatter is ignored —
    /// a note with unusual metadata still indexes on title and body.
    static func parse(markdown: String,
                      fileURL: URL,
                      modifiedAt: Date) -> SearchDocument {
        var tags: [String] = []
        var body = markdown

        if markdown.hasPrefix("---") {
            let lines = markdown.components(separatedBy: "\n")
            if let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                let frontmatter = lines[1..<closing]
                var inTags = false
                for line in frontmatter {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("tags:") {
                        inTags = true
                        let inline = trimmed.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                        if !inline.isEmpty {
                            tags.append(contentsOf: inline
                                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) })
                        }
                        continue
                    }
                    if inTags {
                        if trimmed.hasPrefix("- ") {
                            let value = trimmed.dropFirst(2)
                                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                            if !value.isEmpty { tags.append(value) }
                            continue
                        }
                        if !trimmed.hasPrefix(" ") && !trimmed.isEmpty { inTags = false }
                    }
                }
                body = lines[(closing + 1)...].joined(separator: "\n")
            }
        }

        let headings = LocalTextAnalyzer.markdownHeadings(in: body)
        let title = headings.first { $0.level == 1 }?.text ?? fileURL.deletingPathExtension().lastPathComponent

        return SearchDocument(fileURL: fileURL,
                              title: title,
                              tags: tags.filter { !$0.isEmpty },
                              summary: summarySection(in: body),
                              body: body,
                              modifiedAt: modifiedAt)
    }

    /// The `## 摘要` section written by `MarkdownNoteBuilder`, when present.
    private static func summarySection(in body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("## ") && (trimmed.contains("摘要") || trimmed.lowercased().contains("summary"))
        }) else { return "" }
        var output: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") { break }
            output.append(line)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Structure-aware chunking (spec §20).
///
/// Blocks are separated on blank lines — never inside a fenced code block — and then packed
/// to roughly `targetCharacters`. A block that is itself enormous (a long code listing, a
/// wall of text with no blank lines) is split on sentence boundaries rather than mid-word.
enum SearchChunker {
    /// Soft target: one chunk is about this many characters.
    static let targetCharacters = 420
    /// A chunk is never allowed to grow past this, whatever the block boundaries say.
    /// Spec §20 puts a chunk at 300–600 Chinese characters; a bigger chunk dilutes a single
    /// embedding across too many topics.
    static let maximumCharacters = 600
    /// Chunks smaller than this are merged into the previous one when possible.
    static let minimumCharacters = 100

    static func chunks(for text: String) -> [String] {
        let blocks = markdownBlocks(in: text)
        var output: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { output.append(trimmed) }
            current = ""
        }

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count > maximumCharacters {
                flush()
                output.append(contentsOf: splitLargeBlock(trimmed))
                continue
            }
            if current.isEmpty {
                current = trimmed
                continue
            }
            if current.count + trimmed.count + 2 <= targetCharacters {
                current += "\n\n" + trimmed
            } else {
                // A short tail joins the next block instead of becoming its own chunk.
                if current.count < minimumCharacters {
                    current += "\n\n" + trimmed
                    if current.count >= minimumCharacters { flush() }
                    continue
                }
                flush()
                current = trimmed
            }
        }
        flush()
        return output
    }

    /// Splits Markdown into blank-line-separated blocks while treating a fenced code block
    /// as one indivisible block.
    static func markdownBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var insideFence = false

        func flush() {
            let joined = current.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(joined) }
            current = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                current.append(line)
                if !insideFence { flush() }
                continue
            }
            if insideFence {
                current.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            current.append(line)
        }
        flush()
        return blocks
    }

    /// Splits an oversized block on sentence boundaries, falling back to a hard cut only
    /// when a single "sentence" is longer than the maximum.
    private static func splitLargeBlock(_ block: String) -> [String] {
        if LocalTextAnalyzer.looksLikeFencedCode(block) { return hardWrap(block) }
        let sentences = LocalTextAnalyzer.sentences(in: block, minimumLength: 1)
        guard sentences.count > 1 else { return hardWrap(block) }

        var output: [String] = []
        var current = ""
        for sentence in sentences {
            if sentence.count > maximumCharacters {
                if !current.isEmpty { output.append(current); current = "" }
                output.append(contentsOf: hardWrap(sentence))
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count + 1 <= targetCharacters {
                current += " " + sentence
            } else {
                output.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    private static func hardWrap(_ block: String) -> [String] {
        var output: [String] = []
        var remainder = Substring(block)
        while remainder.count > maximumCharacters {
            let cut = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            output.append(String(remainder[remainder.startIndex..<cut]))
            remainder = remainder[cut...]
        }
        if !remainder.isEmpty { output.append(String(remainder)) }
        return output
    }
}

/// Persisted per-file bookkeeping. A file is only re-indexed when its modification date or
/// content hash changes (spec §22).
struct IndexedFileState: Equatable, Sendable {
    let path: String
    let modifiedAt: Date
    let size: Int
    let contentHash: String
}

/// An embedding row loaded for in-memory similarity search. Note that the note *body* is
/// deliberately absent: the semantic index keeps vectors and metadata only (spec §39).
struct StoredEmbedding: Equatable, Sendable {
    let chunkID: String
    let filePath: String
    let title: String
    let modifiedAt: Date
    let language: String
    let vector: [Float]
}

/// A row returned by the keyword (FTS5/BM25) side.
struct KeywordMatch: Equatable, Sendable {
    let chunkID: String
    let filePath: String
    let title: String
    let excerpt: String
    /// Positive and "bigger is better", already converted from BM25's negative convention.
    let score: Double
    let matchedTerms: [String]
}

enum SearchIndexError: LocalizedError {
    case databaseUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .databaseUnavailable(message):
            return String(localized: "The local search index could not be opened: \(message)")
        }
    }
}
