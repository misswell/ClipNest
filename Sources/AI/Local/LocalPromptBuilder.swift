import Foundation

/// Builds the prompt for the local small model (China plan §20, §21).
///
/// A 0.6B model is not a frontier model: it follows short, explicitly numbered rules far better
/// than prose. Every rule below was added in response to an observed failure on the real
/// weights — with the earlier, terser prompt the model returned the *category list* as the
/// title and the tags, and reduced a five-line capture to its last sentence.
///
/// The prompt no longer owns note-format decisions (方案 §13): the JSON schema is derived
/// from the shared `NoteFormatConfiguration`, so a "title + original" capture asks the model
/// for two fields instead of five and finishes measurably sooner.
///
/// Thinking is not requested here at all. `/no_think` was tried and measurably does not work
/// on this model; the switch that does work is Qwen3's `enable_thinking` template flag, which
/// `MLXQwenEngine` passes to the tokenizer (§21).
struct LocalPromptBuilder: Equatable {
    /// Hard cap on generated tokens (§21). Long enough for a full Markdown body, short
    /// enough that a runaway generation cannot pin the GPU.
    static let maximumTokens = 768

    /// The cap when no body is requested. The answer is a title, a summary, a category and a
    /// few tags — a couple of hundred tokens at most — so this still leaves generous headroom
    /// while halving the worst case.
    static let maximumShortAnswerTokens = 320

    /// Large inputs are truncated on character count before prompting: the model is small
    /// and a 200 KB note would neither fit nor help. The full text is still what gets
    /// saved as the note body, so nothing is lost by trimming the *prompt*.
    static let maximumInputCharacters = 4000

    var maximumInputCharacters: Int = LocalPromptBuilder.maximumInputCharacters
    /// The one shared note format (方案 §6). The prompt is its projection onto this model.
    var format: NoteFormatConfiguration = .default

    var requirements: NoteGenerationRequirements { format.generationRequirements }

    /// Whether the model is asked to write a body at all — this single switch drives both
    /// the schema and the token budget.
    var requiresBody: Bool { requirements.body }

    /// The token budget that matches the requested fields.
    var maximumTokens: Int {
        requiresBody ? Self.maximumTokens : Self.maximumShortAnswerTokens
    }

    /// Handed to the tokenizer's chat template to turn Qwen3's reasoning off (§21).
    ///
    /// This lives here, outside the MLX-only file, for two reasons: it is a property of *this*
    /// model's prompt contract rather than of MLX, and it keeps the decision testable without
    /// a GPU.
    ///
    /// `/no_think` in the prompt text was tried first and measurably does **not** work on
    /// `Qwen3-0.6B-4bit`: the model still emitted a ` thinking` block, which then leaked into
    /// the answer. Qwen3's template branches on `enable_thinking`, which is what actually
    /// suppresses it.
    static let chatTemplateContext: [String: Bool] = ["enable_thinking": false]

    func prompt(for content: ClipboardContent,
                existingCategories: [String],
                preferredLanguage: PreferredLanguage) -> String {
        let text = Self.condensed(content.text, limit: maximumInputCharacters)
        let wanted = requirements

        var fields: [String] = []
        if wanted.title { fields.append("\"title\":\"...\"") }
        if wanted.summary { fields.append("\"summary\":\"...\"") }
        if wanted.body { fields.append("\"content\":\"...\"") }
        // Classification stays requested even when the note renders none of it (方案 §30).
        fields.append("\"category\":\"...\"")
        if wanted.tags { fields.append("\"tags\":[\"...\"]") }

        var rules: [String] = []
        var number = 1
        if wanted.title {
            rules.append("\(number). title：原文主题，20 字以内，不要使用分类名。")
            number += 1
        }
        if wanted.summary {
            rules.append("\(number). summary：1-3 句，覆盖原文全部要点。")
            number += 1
        }
        if wanted.body {
            rules.append(Self.bodyRule(number: number, format: format))
            number += 1
        }
        if wanted.tags {
            rules.append("\(number). tags：2-5 个关键词，必须是原文里出现过的词，不要使用分类名。")
            number += 1
        }

        // The category list is stated once, inside the rule that governs it. Listing it on its
        // own line next to the source is what made the model copy it into the title and tags.
        rules.append(Self.categoryRule(number: number, existingCategories: existingCategories))
        number += 1
        rules.append("\(number). 禁止编造原文没有的信息。\(preferredLanguage.generationInstruction)")
        number += 1

        // Fields the format does not want are ruled out *by name*: naming what must not be
        // produced is what stopped the model adding the field anyway (§20).
        let excluded = Self.excludedFields(requirements: wanted)
        if !excluded.isEmpty {
            let joined = excluded.joined(separator: "、")
            let reason = excluded.contains("content") ? "，正文由程序保留原文" : ""
            rules.append("\(number). 不要输出 \(joined) 字段\(reason)。")
        }

        return """
        你是 ClipNest 笔记整理器。阅读原文，只返回一个 JSON 对象：
        {\(fields.joined(separator: ","))}

        规则：
        \(rules.joined(separator: "\n"))

        原文：
        \(text)
        """
    }

    /// The body rule, including the format's style directive (方案 §12). A custom style
    /// carries the user's own compressed instruction instead.
    private static func bodyRule(number: Int, format: NoteFormatConfiguration) -> String {
        let base = "\(number). content：把原文完整整理成 Markdown，保留所有要点、代码、数字和 URL，不能只写一两句"
        if format.bodyStyle == .custom {
            let instruction = format.localInstruction
            guard !instruction.isEmpty else { return base + "。" }
            return base + "。风格要求：\(instruction)"
        }
        guard let style = format.bodyStyle.localStyleInstruction else { return base + "。" }
        return base + "，\(style)"
    }

    private static func categoryRule(number: Int, existingCategories: [String]) -> String {
        existingCategories.isEmpty
            ? "\(number). category：没有可选分类，填空字符串 \"\"。"
            : """
              \(number). category：只能从这些分类里原样选一个，都不合适就填空字符串 ""。
                 可选分类：\(categoryList(existingCategories))
              """
    }

    private static func excludedFields(requirements: NoteGenerationRequirements) -> [String] {
        var excluded: [String] = []
        if !requirements.body { excluded.append("content") }
        if !requirements.summary { excluded.append("summary") }
        if !requirements.tags { excluded.append("tags") }
        return excluded
    }

    /// The category list is a closed set: the model may choose from it, or return an empty
    /// string. `ClassificationService` still has the final say (§35).
    private static func categoryList(_ categories: [String]) -> String {
        let cleaned = categories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "（无，可留空）" }
        return cleaned.joined(separator: "、")
    }

    /// Trims to a budget without cutting mid-line where possible, so code and tables stay
    /// readable for the model.
    static func condensed(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let head = String(trimmed.prefix(limit))
        // Prefer a line boundary inside the last 15% of the budget.
        let floor = limit - max(1, limit / 7)
        if let newline = head.lastIndex(of: "\n"),
           head.distance(from: head.startIndex, to: newline) >= floor {
            return String(head[head.startIndex..<newline])
        }
        return head
    }
}
