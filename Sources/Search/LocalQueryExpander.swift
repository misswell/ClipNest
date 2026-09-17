import Foundation

/// Turns a short user query into a few related keywords using the on-device model (China plan
/// §25).
///
/// This is a pure enhancement and is treated as one:
/// - no model installed → no expansion, the raw FTS query runs unchanged;
/// - the model is slow → a hard timeout abandons it and the raw results stay on screen;
/// - the answer is nonsense → every candidate is validated before it reaches FTS.
///
/// Expansion never *replaces* the user's terms, so a bad expansion can add noise but can never
/// hide the note that matched the query literally.
struct LocalQueryExpander: Sendable {
    /// Enough to catch synonyms; more would drown the literal match.
    static let maximumKeywords = 4
    /// A search field must stay responsive. Past this the raw-query results are final.
    static let defaultTimeout = Duration.milliseconds(700)
    /// Expanding a single character widens the search to most of the vault.
    static let minimumQueryCharacters = 2

    /// Returns an engine when a usable model is installed, otherwise nil.
    var makeEngine: @Sendable () async -> (any LocalTextGenerating)?
    var timeout: Duration = Self.defaultTimeout
    var cache: LocalQueryExpansionCache?

    init(makeEngine: @escaping @Sendable () async -> (any LocalTextGenerating)? = Self.defaultEngine,
         timeout: Duration = Self.defaultTimeout,
         cache: LocalQueryExpansionCache? = .shared) {
        self.makeEngine = makeEngine
        self.timeout = timeout
        self.cache = cache
    }

    /// The production source of an engine: the downloaded model, if it is installed and the
    /// runtime is linked into this build.
    static let defaultEngine: @Sendable () async -> (any LocalTextGenerating)? = {
        guard LocalModelRuntime.isRuntimeLinked else { return nil }
        guard let store = await LocalModelManager.shared.readyStore() else { return nil }
        return try? await LocalModelRuntime.shared.engine(for: store.modelDirectory)
    }

    /// Extra keywords to OR into the FTS expression. Empty means "search the query as written".
    func expand(_ query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryCharacters else { return [] }

        if let cached = await cache?.keywords(for: trimmed) { return cached }
        guard let engine = await makeEngine() else { return [] }

        let keywords = await keywords(from: engine, query: trimmed)
        await cache?.store(keywords, for: trimmed)
        return keywords
    }

    private func keywords(from engine: any LocalTextGenerating, query: String) async -> [String] {
        let prompt = Self.prompt(for: query)
        let generated = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await engine.generate(prompt: prompt, maximumTokens: 96)
            }
            group.addTask {
                // Losing the race is the normal outcome on a slow device, and costs nothing:
                // the caller falls back to the raw query.
                try? await Task.sleep(for: self.timeout)
                return nil
            }
            var first: String?
            for await result in group {
                first = result
                group.cancelAll()
                break
            }
            return first
        }

        guard let generated else { return [] }
        // A model that timed out was cancelled; it must not be asked for anything else.
        guard !Task.isCancelled else { return [] }
        return Self.parse(generated, excluding: query)
    }

    // MARK: - Prompt

    /// Deliberately tiny: this is a latency-critical path, and a 0.6B model does better with a
    /// one-line instruction than with an elaborate one.
    static func prompt(for query: String) -> String {
        """
        /no_think
        为搜索扩展关键词。只输出 2-4 个与下面查询相关的中文或英文关键词，用逗号分隔，不要解释。
        查询：\(query)
        """
    }

    // MARK: - Parsing

    /// Accepts the several shapes a small model actually produces: commas, Chinese commas,
    /// newlines, bullets, numbered lists, quotes and a stray JSON array.
    static func parse(_ raw: String, excluding query: String) -> [String] {
        // Measured on the real weights: even with thinking disabled the model can still emit a
        // reasoning block. Left in place, its `<think>` markers came out as "keywords" and were
        // OR'd straight into the FTS expression.
        var text = LocalGeneratedNoteDecoder.strippingThinkBlocks(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            text = String(text[text.index(after: start)..<end])
        }

        let separators = CharacterSet(charactersIn: ",，、;；\n\t|/<>")
            .union(CharacterSet(charactersIn: "\"'[]{}*#-•"))
        let existing = Set(LocalTextAnalyzer.tokens(in: query).map(LocalTextAnalyzer.normalizedKey)
            + [LocalTextAnalyzer.normalizedKey(query)])

        var seen = Set<String>()
        var output: [String] = []
        for piece in text.components(separatedBy: separators) {
            let candidate = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate.count <= 24 else { continue }
            // Prose is not a keyword. A model that ignored the instruction and answered in
            // sentences would otherwise poison the query with whole clauses.
            guard candidate.split(separator: " ").count <= 3 else { continue }
            guard !candidate.contains("："), !candidate.contains(":") else { continue }
            guard !candidate.lowercased().hasPrefix("关键词") else { continue }
            let key = LocalTextAnalyzer.normalizedKey(candidate)
            guard !key.isEmpty, !LocalTextAnalyzer.stopwords.contains(key) else { continue }
            guard !existing.contains(key) else { continue }
            guard seen.insert(key).inserted else { continue }
            output.append(candidate)
            if output.count == maximumKeywords { break }
        }
        return output
    }
}

/// Memoises expansions for the session. Typing re-issues the same query repeatedly (a
/// backspace, a re-render, a mode toggle), and each miss would otherwise cost a model run.
actor LocalQueryExpansionCache {
    static let shared = LocalQueryExpansionCache()

    private var entries: [String: [String]] = [:]
    private let limit = 64

    func keywords(for query: String) -> [String]? { entries[query] }

    func store(_ keywords: [String], for query: String) {
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[query] = keywords
    }

    func removeAll() { entries.removeAll() }
}
