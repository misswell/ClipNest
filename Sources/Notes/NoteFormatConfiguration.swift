import Foundation

/// The built-in note shapes offered in Settings (方案 §5, §24).
///
/// A preset is a *starting point*: the moment the user flips any toggle the configuration
/// re-derives its preset (`.custom` when it matches nothing), so presets never fight the
/// user's own combination.
enum NoteFormatPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case clean
    case original
    case archive
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return String(localized: "Standard Note")
        case .clean: return String(localized: "Clean Note")
        case .original: return String(localized: "Title + Original")
        case .archive: return String(localized: "Full Archive")
        case .custom: return String(localized: "Custom")
        }
    }

    /// One line under the picker in Settings (方案 §24).
    var explanation: String {
        switch self {
        case .standard:
            return String(localized: "Title, summary, the source as the body, tags and metadata.")
        case .clean:
            return String(localized: "Title and organized content only.")
        case .original:
            return String(localized: "Generate a title and preserve the source exactly.")
        case .archive:
            return String(localized: "Keep the organized body, the original text and all source material.")
        case .custom:
            return String(localized: "Your own combination of sections and style.")
        }
    }

    /// The toggle configuration a preset stands for. `.custom` has none of its own — it is
    /// purely what the picker shows when the toggles match no built-in preset.
    var configuration: NoteFormatConfiguration? {
        switch self {
        case .custom:
            return nil
        case .standard:
            return .standard
        case .clean:
            return .clean
        case .original:
            return .titleAndOriginal
        case .archive:
            return .archive
        }
    }
}

/// How an organized body is written when one is produced at all (方案 §12).
///
/// `.original` is special: no body is requested from any model and the program uses the
/// source text. It is the merge target of the old `LocalBodyStyle.sourceVerbatim`, which is
/// why the shipping default keeps it — the measured decision that the on-device model should
/// not spend its budget rewriting bodies stays intact (方案 §34).
enum NoteBodyStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case concise
    case knowledge
    case structured
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return String(localized: "Keep the original text")
        case .concise: return String(localized: "Concise rewrite")
        case .knowledge: return String(localized: "Knowledge note")
        case .structured: return String(localized: "Structured note")
        case .custom: return String(localized: "Custom")
        }
    }

    var explanation: String {
        switch self {
        case .original:
            return String(localized: "The AI writes the title, summary, tags and category; the body is your own text. Fastest on device, and a fact can never be lost in a rewrite.")
        case .concise:
            return String(localized: "Remove repetition and filler while keeping every fact — no padding.")
        case .knowledge:
            return String(localized: "Organize into a note worth rereading, with headings, lists and code blocks.")
        case .structured:
            return String(localized: "Group into natural sections and pull out the key points and parameters without inventing any.")
        case .custom:
            return String(localized: "Use your own instruction below.")
        }
    }

    /// The directive the online prompt carries for this style (方案 §12). `.original` and
    /// `.custom` need no fixed sentence: the former requests no body, the latter uses the
    /// user's own instruction.
    var styleInstruction: String? {
        switch self {
        case .original, .custom:
            return nil
        case .concise:
            return "删除明显重复内容和无意义口语，保持所有有效事实，不要扩写。"
        case .knowledge:
            return "整理为适合长期阅读的知识笔记，合理使用 Markdown 标题、列表、代码块。"
        case .structured:
            return "根据内容自然组织章节，提取重点、步骤和关键参数，但不得补充原文不存在的事实。"
        }
    }

    /// The compressed variant the 0.6B on-device model gets — every character competes with
    /// the source text for its tiny context (方案 §13).
    var localStyleInstruction: String? {
        switch self {
        case .original, .custom:
            return nil
        case .concise:
            return "删除重复和口语，保持全部事实，不要扩写。"
        case .knowledge:
            return "整理成适合长期阅读的知识笔记，用好标题、列表和代码块。"
        case .structured:
            return "按内容自然分章，提取重点和参数，不补充原文没有的事实。"
        }
    }
}

/// How an attached image is referenced from the Markdown (方案 §19).
enum ImageLinkStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `![alt](../Attachments/x.jpg)` — plain Markdown, the most portable default.
    case markdown
    /// `![[Attachments/x.jpg]]` — Obsidian embeds.
    case obsidian

    var id: String { rawValue }
}

/// What the AI is actually asked to produce for one capture (方案 §9).
///
/// Derived from `NoteFormatConfiguration` — never stored — so the prompts can shrink the
/// JSON schema to exactly the fields the note will use. `category` stays on unconditionally:
/// automatic classification is internal metadata, independent of what the rendered note
/// shows (方案 §30).
struct NoteGenerationRequirements: Equatable, Sendable {
    var title: Bool
    var summary: Bool
    var body: Bool
    var category: Bool
    var tags: Bool

    static let full = NoteGenerationRequirements(title: true,
                                                 summary: true,
                                                 body: true,
                                                 category: true,
                                                 tags: true)
}

/// The single source of truth for what a generated note looks like (方案 §6).
///
/// One object governs the online provider, the on-device model and the Markdown renderer.
/// Nothing else may keep a parallel notion of "note format" — the old `LocalBodyStyle` was
/// migrated into this type and deprecated (方案 §34).
struct NoteFormatConfiguration: Codable, Equatable, Sendable {
    var preset: NoteFormatPreset

    var includeTitle: Bool
    var includeSummary: Bool
    var includeGeneratedBody: Bool
    var includeOriginalText: Bool
    var includeOriginalImage: Bool

    var includeTags: Bool
    var includeFrontmatter: Bool
    var includeSourceURL: Bool
    var includeCreatedAt: Bool

    var customInstruction: String
    var bodyStyle: NoteBodyStyle
    var imageLinkStyle: ImageLinkStyle

    /// The shipping default (方案 §8): the Standard preset with the source kept as the body.
    /// That is byte-compatible with what the local pipeline already produced — the model does
    /// the four things it is good at and the body is the user's own text.
    static let `default` = NoteFormatConfiguration.standard

    /// 标准笔记 (方案 §5 Standard, tuned by §8 for upgrade compatibility).
    ///
    /// The body comes from the source text (`.original` style), so `includeGeneratedBody`
    /// is off by the same AND-rule the prompts and renderer use — the shipped default keeps
    /// the measured fast local path instead of paying for bodies the fact guard discarded.
    static let standard = NoteFormatConfiguration(
        preset: .standard,
        includeTitle: true,
        includeSummary: true,
        includeGeneratedBody: false,
        includeOriginalText: true,
        includeOriginalImage: true,
        includeTags: true,
        includeFrontmatter: true,
        includeSourceURL: true,
        includeCreatedAt: true,
        customInstruction: "",
        bodyStyle: .original,
        imageLinkStyle: .markdown
    )

    /// 精简笔记: title + organized body, nothing else (方案 §5 Clean).
    static let clean = NoteFormatConfiguration(
        preset: .clean,
        includeTitle: true,
        includeSummary: false,
        includeGeneratedBody: true,
        includeOriginalText: false,
        includeOriginalImage: true,
        includeTags: false,
        includeFrontmatter: false,
        includeSourceURL: false,
        includeCreatedAt: false,
        customInstruction: "",
        bodyStyle: .knowledge,
        imageLinkStyle: .markdown
    )

    /// 标题 + 原文: the model only names and classifies; the source is preserved verbatim
    /// (方案 §5 Original). The smallest possible local generation (方案 §9).
    static let titleAndOriginal = NoteFormatConfiguration(
        preset: .original,
        includeTitle: true,
        includeSummary: false,
        includeGeneratedBody: false,
        includeOriginalText: true,
        includeOriginalImage: true,
        includeTags: false,
        includeFrontmatter: false,
        includeSourceURL: false,
        includeCreatedAt: false,
        customInstruction: "",
        bodyStyle: .original,
        imageLinkStyle: .markdown
    )

    /// 完整归档: everything, with an organized body on top of the preserved source (方案 §5 Archive).
    static let archive = NoteFormatConfiguration(
        preset: .archive,
        includeTitle: true,
        includeSummary: true,
        includeGeneratedBody: true,
        includeOriginalText: true,
        includeOriginalImage: true,
        includeTags: true,
        includeFrontmatter: true,
        includeSourceURL: true,
        includeCreatedAt: true,
        customInstruction: "",
        bodyStyle: .knowledge,
        imageLinkStyle: .markdown
    )

    /// Decoding tolerates missing keys so adding fields later is a migration-free default
    /// (方案 §7). Unknown *values* (a preset removed in a future release) fall back too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NoteFormatConfiguration.standard
        preset = try container.decodeIfPresent(NoteFormatPreset.self, forKey: .preset) ?? fallback.preset
        includeTitle = try container.decodeIfPresent(Bool.self, forKey: .includeTitle) ?? fallback.includeTitle
        includeSummary = try container.decodeIfPresent(Bool.self, forKey: .includeSummary) ?? fallback.includeSummary
        includeGeneratedBody = try container.decodeIfPresent(Bool.self, forKey: .includeGeneratedBody) ?? fallback.includeGeneratedBody
        includeOriginalText = try container.decodeIfPresent(Bool.self, forKey: .includeOriginalText) ?? fallback.includeOriginalText
        includeOriginalImage = try container.decodeIfPresent(Bool.self, forKey: .includeOriginalImage) ?? fallback.includeOriginalImage
        includeTags = try container.decodeIfPresent(Bool.self, forKey: .includeTags) ?? fallback.includeTags
        includeFrontmatter = try container.decodeIfPresent(Bool.self, forKey: .includeFrontmatter) ?? fallback.includeFrontmatter
        includeSourceURL = try container.decodeIfPresent(Bool.self, forKey: .includeSourceURL) ?? fallback.includeSourceURL
        includeCreatedAt = try container.decodeIfPresent(Bool.self, forKey: .includeCreatedAt) ?? fallback.includeCreatedAt
        customInstruction = try container.decodeIfPresent(String.self, forKey: .customInstruction) ?? ""
        bodyStyle = try container.decodeIfPresent(NoteBodyStyle.self, forKey: .bodyStyle) ?? fallback.bodyStyle
        imageLinkStyle = try container.decodeIfPresent(ImageLinkStyle.self, forKey: .imageLinkStyle) ?? .markdown
    }

    init(preset: NoteFormatPreset,
         includeTitle: Bool,
         includeSummary: Bool,
         includeGeneratedBody: Bool,
         includeOriginalText: Bool,
         includeOriginalImage: Bool,
         includeTags: Bool,
         includeFrontmatter: Bool,
         includeSourceURL: Bool,
         includeCreatedAt: Bool,
         customInstruction: String,
         bodyStyle: NoteBodyStyle,
         imageLinkStyle: ImageLinkStyle) {
        self.preset = preset
        self.includeTitle = includeTitle
        self.includeSummary = includeSummary
        self.includeGeneratedBody = includeGeneratedBody
        self.includeOriginalText = includeOriginalText
        self.includeOriginalImage = includeOriginalImage
        self.includeTags = includeTags
        self.includeFrontmatter = includeFrontmatter
        self.includeSourceURL = includeSourceURL
        self.includeCreatedAt = includeCreatedAt
        self.customInstruction = customInstruction
        self.bodyStyle = bodyStyle
        self.imageLinkStyle = imageLinkStyle
    }
}

extension NoteFormatConfiguration {
    /// Whether an AI-generated body is actually part of this format. `.original` style means
    /// the source text *is* the body, so no model is asked for one (方案 §12, §34).
    var generatesBody: Bool {
        includeGeneratedBody && bodyStyle != .original
    }

    /// The fields the AI should produce for this format (方案 §9).
    var generationRequirements: NoteGenerationRequirements {
        NoteGenerationRequirements(
            title: includeTitle,
            summary: includeSummary,
            body: generatesBody,
            category: true,
            tags: includeTags
        )
    }

    /// The custom instruction as the user typed it, whitespace-trimmed.
    var trimmedCustomInstruction: String {
        customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hard cap on the stored instruction (方案 §26).
    static let maximumInstructionCharacters = 2000
    /// What the 0.6B model sees of it — its context and instruction-following are tiny (方案 §26).
    static let maximumLocalInstructionCharacters = 400

    /// The instruction the online model gets: the full text, capped defensively (方案 §26).
    var onlineInstruction: String {
        String(trimmedCustomInstruction.prefix(Self.maximumInstructionCharacters))
    }

    /// The instruction the on-device model gets: a short prefix, computed here rather than
    /// kept as a second input field in the UI (方案 §26).
    var localInstruction: String {
        String(trimmedCustomInstruction.prefix(Self.maximumLocalInstructionCharacters))
    }

    /// The preset this configuration currently *is*, by value rather than by the stored
    /// label — flipping a toggle instantly re-derives it (方案 §24).
    var resolvedPreset: NoteFormatPreset {
        NoteFormatPreset.allCases.first { $0.configuration == self } ?? .custom
    }

    /// Returns the configuration with `preset`'s toggles applied. `.custom` keeps the current
    /// toggles (it only licenses the custom instruction field), so the picker never destroys
    /// the user's combination.
    func applyingPreset(_ preset: NoteFormatPreset) -> NoteFormatConfiguration {
        guard var updated = preset.configuration else { return self }
        updated.customInstruction = customInstruction
        updated.imageLinkStyle = imageLinkStyle
        updated.preset = preset
        return updated
    }

    /// Returns the configuration with one custom instruction update, re-deriving the preset.
    func updatingCustomInstruction(_ instruction: String) -> NoteFormatConfiguration {
        var updated = self
        updated.customInstruction = String(instruction.prefix(Self.maximumInstructionCharacters))
        updated.preset = updated.resolvedPreset
        return updated
    }
}

/// Persists `NoteFormatConfiguration` as one JSON blob (方案 §7).
///
/// The first load of an existing install migrates the deprecated `LocalBodyStyle` instead of
/// changing that user's note shape (方案 §8, §34): local users kept the source-verbatim body
/// they already had, online users kept a model-written body, and `modelRewrite` maps to the
/// knowledge style.
enum NoteFormatConfigurationStore {
    static func load(defaults: UserDefaults = .standard) -> NoteFormatConfiguration {
        if let data = defaults.data(forKey: ClipNestSettings.noteFormatConfiguration),
           let configuration = try? JSONDecoder().decode(NoteFormatConfiguration.self, from: data) {
            return configuration
        }
        if let migrated = legacyConfiguration(defaults: defaults) {
            save(migrated, defaults: defaults)
            return migrated
        }
        return .default
    }

    static func save(_ configuration: NoteFormatConfiguration, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: ClipNestSettings.noteFormatConfiguration)
    }

    /// The configuration an upgrading user should keep, or `nil` for a fresh install.
    static func legacyConfiguration(defaults: UserDefaults) -> NoteFormatConfiguration? {
        legacyConfiguration(defaults: defaults,
                            processingMode: AIConfigurationStore.loadProcessingMode())
    }

    /// - Parameter processingMode: injected so the rule can be exercised without writing to
    ///   global user defaults (which would leak between tests).
    static func legacyConfiguration(defaults: UserDefaults,
                                    processingMode: AIProcessingMode) -> NoteFormatConfiguration? {
        let hasCapturedBefore = defaults.object(forKey: ClipNestSettings.lastClipboardHash) != nil
            || defaults.object(forKey: ClipNestSettings.lastAttemptedClipboardHash) != nil
        // The deprecated key's raw value, read without resurrecting the old enum.
        let legacyBodyStyle = defaults.string(forKey: ClipNestSettings.localBodyStyle)
        guard hasCapturedBefore || legacyBodyStyle != nil else { return nil }

        let legacyRewroteBodies = legacyBodyStyle == "modelRewrite"
        var configuration = NoteFormatConfiguration.standard
        // An online user's old notes carried a model-written body; a local user's did not.
        if processingMode == .online || legacyRewroteBodies {
            configuration.bodyStyle = .knowledge
            configuration.includeGeneratedBody = true
        }
        configuration.preset = configuration.resolvedPreset
        return configuration
    }
}
