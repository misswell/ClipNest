import Foundation

/// Local note generation backed by a small on-device LLM (China plan §15, §20–§23).
///
/// This type owns everything that is *not* MLX: the prompt, the tolerant JSON read, the
/// repair of incomplete answers, and the mapping onto the one `GeneratedNote` every
/// provider returns. The weights live behind `LocalTextGenerating`, so this code is
/// testable without a GPU or a 350 MB download.
///
/// It never invents: any field the model leaves empty is filled from the source text using
/// the same extractors Local Lite uses, and if the answer is not usable JSON at all the
/// caller degrades to Local Lite (§22).
struct QwenLocalProvider: ProgressReportingNoteGenerating {
    let engine: any LocalTextGenerating
    var profiles: [CategoryProfile]
    var promptBuilder: LocalPromptBuilder
    var classifier: LocalSemanticClassifier
    var summarizer: LocalSummarizer
    var tagExtractor: LocalTagExtractor

    init(engine: any LocalTextGenerating,
         profiles: [CategoryProfile] = [],
         promptBuilder: LocalPromptBuilder = LocalPromptBuilder(),
         classifier: LocalSemanticClassifier = LocalSemanticClassifier(),
         summarizer: LocalSummarizer = LocalSummarizer(),
         tagExtractor: LocalTagExtractor = LocalTagExtractor()) {
        self.engine = engine
        self.profiles = profiles
        self.promptBuilder = promptBuilder
        self.classifier = classifier
        self.summarizer = summarizer
        self.tagExtractor = tagExtractor
    }

    var engineName: String { engine.engineName }

    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        try await generate(from: content,
                           existingCategories: existingCategories,
                           preferredLanguage: preferredLanguage,
                           onProgress: nil)
    }

    /// The same capture, reporting what it is doing while it does it.
    ///
    /// `onProgress` is called off the main actor, several times a second while the model
    /// streams. It is optional in both directions: `nil` means "don't report", and an engine
    /// that cannot stream (Local Lite, or a scripted test engine) simply produces one final
    /// `.generating` before the answer lands.
    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage,
                  onProgress: (@Sendable (NoteGenerationProgress) -> Void)?) async throws -> GeneratedNote {
        let text = content.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIError.emptyInput
        }

        let prompt = promptBuilder.prompt(for: content,
                                          existingCategories: existingCategories,
                                          preferredLanguage: preferredLanguage)

        // The load phase is reported first and only when a load will actually happen: it is a
        // real wait that finishes before any output exists, so announcing "writing" first would
        // make the banner flip backwards.
        if let onProgress, let preparing = engine as? LocalTextPreparing, await !preparing.isPrepared {
            onProgress(.preparingEngine(engineName: engine.engineName))
        }

        let fields = try await decodeWithOneRetry(prompt: prompt, onProgress: onProgress)

        onProgress?(.finishing)
        return assemble(fields: fields,
                        source: content,
                        text: text,
                        existingCategories: existingCategories,
                        preferredLanguage: preferredLanguage)
    }

    /// Produces the parsed fields, retrying once if the model did not answer with an object.
    ///
    /// Measured against the real weights: roughly one generation in thirty comes back as prose
    /// or a bare ` thinking` block instead of the requested JSON. Without this, every one of those
    /// silently costs the capture its downloaded-model path and drops to Local Lite. A retry
    /// costs about a second and only happens on the answers that were going to be discarded.
    ///
    /// Exactly one retry: a second failure is a real signal (broken weights, a bad prompt), and
    /// retrying further would just make the capture slower without making it succeed.
    private func decodeWithOneRetry(prompt: String,
                                    onProgress: (@Sendable (NoteGenerationProgress) -> Void)?) async throws -> LocalGeneratedNoteFields {
        let first = try await rawAnswer(prompt: prompt, onProgress: onProgress)
        if let fields = try? LocalGeneratedNoteDecoder.decode(first) {
            return fields
        }

        let second = try await rawAnswer(prompt: prompt, onProgress: onProgress)
        do {
            return try LocalGeneratedNoteDecoder.decode(second)
        } catch {
            throw LocalAIError.generationFailed(
                (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "Unreadable model output"))
        }
    }

    private func rawAnswer(prompt: String,
                           onProgress: (@Sendable (NoteGenerationProgress) -> Void)?) async throws -> String {
        do {
            return try await run(prompt: prompt, onProgress: onProgress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalAIError {
            throw error
        } catch {
            // A model that is installed but cannot run is a *local* problem: the router
            // degrades to Local Lite, never to the network.
            throw LocalAIError.generationFailed(error.localizedDescription)
        }
    }

    /// Runs the completion, streaming into a preview when the engine supports it.
    private func run(prompt: String,
                     onProgress: (@Sendable (NoteGenerationProgress) -> Void)?) async throws -> String {
        let maximumTokens = promptBuilder.maximumTokens

        guard let onProgress else {
            return try await engine.generate(prompt: prompt, maximumTokens: maximumTokens)
        }

        guard let streaming = engine as? LocalTextStreaming else {
            // No streaming available: run normally, then hand over the finished answer once.
            let answer = try await engine.generate(prompt: prompt, maximumTokens: maximumTokens)
            onProgress(.generating(preview: Self.preview(for: answer)))
            return answer
        }

        // The preview is read from the raw answer, never from the assembled note, so the user
        // is never shown a title the guards would later replace.
        return try await streaming.generate(prompt: prompt,
                                            maximumTokens: maximumTokens) { accumulated in
            onProgress(.generating(preview: Self.preview(for: accumulated)))
        }
    }

    /// What can already be shown of a partial answer.
    private static func preview(for answer: String) -> NotePreview {
        NotePreview(title: LocalPartialJSON.string("title", in: answer),
                    summary: LocalPartialJSON.string("summary", in: answer),
                    tags: LocalPartialJSON.strings("tags", in: answer),
                    charactersGenerated: answer.count)
    }

    /// Fills in whatever the model omitted, without ever discarding what it produced.
    private func assemble(fields: LocalGeneratedNoteFields,
                          source: ClipboardContent,
                          text: String,
                          existingCategories: [String],
                          preferredLanguage: PreferredLanguage) -> GeneratedNote {
        let title = resolvedTitle(fields.title, text: text, preferredLanguage: preferredLanguage)
        let summary = fields.summary.isEmpty
            ? summarizer.summarize(text, title: title)
            : fields.summary
        // With `.sourceVerbatim` there is no model body to weigh: the source *is* the body, so
        // the fact-preservation guard has nothing to reject and cannot be the reason a capture
        // looks different from the fast path.
        let content = promptBuilder.bodyStyle == .sourceVerbatim
            ? MarkdownContentCleaner.clean(text)
            : resolvedContent(fields.content, text: text, title: title)
        let category = resolvedCategory(fields.category,
                                        text: text,
                                        existingCategories: existingCategories)
        let tags = resolvedTags(fields.tags,
                                text: text,
                                title: title,
                                category: category,
                                existingCategories: existingCategories)

        return GeneratedNote(title: title,
                             summary: summary,
                             content: content,
                             category: category,
                             tags: tags,
                             sourceURL: source.sourceURL)
    }

    /// Tags are repaired rather than trusted, for two measured reasons.
    ///
    /// The model sometimes answers with the *category list* it was shown — three of five
    /// samples did — and a tag identical to the folder the note is already filed in carries no
    /// information anyway, so those are dropped. If that empties the list, the extractor
    /// supplies keywords from the source instead of shipping a note with no tags.
    private func resolvedTags(_ candidate: [String],
                              text: String,
                              title: String,
                              category: String,
                              existingCategories: [String]) -> [String] {
        let forbidden = Set((existingCategories + [category])
            .map { LocalTextAnalyzer.normalizedKey($0) }
            .filter { !$0.isEmpty })

        var seen = Set<String>()
        let kept = candidate.filter { tag in
            let key = LocalTextAnalyzer.normalizedKey(tag)
            guard !key.isEmpty, !forbidden.contains(key) else { return false }
            return seen.insert(key).inserted
        }
        guard !kept.isEmpty else { return tagExtractor.tags(in: text, title: title) }
        return kept
    }

    private func resolvedTitle(_ candidate: String,
                               text: String,
                               preferredLanguage: PreferredLanguage) -> String {
        let cleaned = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#* \t"))
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty else {
            return LocalTitleExtractor.title(for: text, preferredLanguage: preferredLanguage)
        }
        return cleaned
    }

    /// A model that fenced the whole body is unwrapped; a body that is legitimately a code
    /// listing is left intact (see `strippingOuterMarkdownFence`).
    ///
    /// A body that has dropped protected facts is rejected in favour of the cleaned source.
    /// Measured on the real weights this is not hypothetical: across five samples of one
    /// capture the model silently dropped the measurement `iPhone 15 Pro / 0.4 秒` three
    /// times while still producing well-formed JSON (§20, §22).
    private func resolvedContent(_ candidate: String, text: String, title: String) -> String {
        let source = MarkdownContentCleaner.clean(text)
        let cleaned = LocalGeneratedNoteDecoder.strippingOuterMarkdownFence(candidate)
        guard !cleaned.isEmpty else { return source }
        // A model that echoed its own JSON instead of writing a body has produced nothing.
        if cleaned.hasPrefix("{"), cleaned.contains("\"title\"") { return source }
        if LocalFactPreservation.losesFacts(modelBody: cleaned, title: title, source: source) {
            return source
        }
        return cleaned
    }

    /// The model may only *choose* from the categories it was given (§20). Anything else is
    /// discarded and the local classifier decides instead, so a hallucinated folder name can
    /// never reach the vault. `ClassificationService` remains the final safety net (§35).
    private func resolvedCategory(_ candidate: String,
                                  text: String,
                                  existingCategories: [String]) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let match = existingCategories.first(where: {
               $0.trimmingCharacters(in: .whitespacesAndNewlines)
                   .caseInsensitiveCompare(trimmed) == .orderedSame
           }) {
            return match
        }

        let effective = profiles.isEmpty
            ? existingCategories.map { CategoryProfile(name: $0) }
            : profiles
        return classifier.classify(text: text, categories: effective).category ?? ""
    }
}
