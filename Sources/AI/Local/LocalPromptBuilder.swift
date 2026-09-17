import Foundation

/// How the note body is produced.
///
/// Measured on real weights, on device: of six captures the model's rewritten body survived the
/// fact-preservation guard **once**. The other five times the body was discarded for the
/// cleaned source — after the decode phase had already spent ~5 s producing it. Since the body
/// is most of the decoded tokens, asking for it was the single largest source of wasted time in
/// the whole capture.
///
/// So the default is `.sourceVerbatim`: the model does the four things it is actually good at
/// and kept for (title, summary, tags, category) and the body is the user's own text. This is
/// not a speed/quality compromise — for the five-of-six case the saved note is *byte-identical*
/// to what the slow path produced, and it can no longer drop a fact because it never rewrites
/// one.
enum LocalBodyStyle: String, CaseIterable, Sendable {
    /// The body is the cleaned source; the model is not asked for one.
    case sourceVerbatim
    /// The model rewrites the body, with the fact-preservation guard as the safety net.
    case modelRewrite

    static let `default`: LocalBodyStyle = .sourceVerbatim

    var displayName: String {
        switch self {
        case .sourceVerbatim: return String(localized: "Keep the original text")
        case .modelRewrite: return String(localized: "Let the model rewrite it")
        }
    }

    /// Short line under the picker in Settings.
    var explanation: String {
        switch self {
        case .sourceVerbatim:
            return String(localized: "Fastest, and the body can never lose a fact. The model still writes the title, summary, tags and category.")
        case .modelRewrite:
            return String(localized: "The model also restructures the body. Slower, and it falls back to your original text whenever a fact would be lost.")
        }
    }
}

/// Builds the prompt for the local small model (China plan §20, §21).
///
/// A 0.6B model is not a frontier model: it follows short, explicitly numbered rules far better
/// than prose. Every rule below was added in response to an observed failure on the real
/// weights — with the earlier, terser prompt the model returned the *category list* as the
/// title and the tags, and reduced a five-line capture to its last sentence.
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
    var bodyStyle: LocalBodyStyle = .default

    /// The token budget that matches `bodyStyle`.
    var maximumTokens: Int {
        bodyStyle == .modelRewrite ? Self.maximumTokens : Self.maximumShortAnswerTokens
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
        let categories = Self.categoryList(existingCategories)

        // The category list is stated once, inside the rule that governs it. Listing it on its
        // own line next to the source is what made the model copy it into the title and tags.
        let categoryRuleNumber = bodyStyle == .modelRewrite ? 5 : 4
        let categoryRule = existingCategories.isEmpty
            ? "\(categoryRuleNumber). category：没有可选分类，填空字符串 \"\"。"
            : """
              \(categoryRuleNumber). category：只能从这些分类里原样选一个，都不合适就填空字符串 ""。
                 可选分类：\(categories)
              """

        let finalRuleNumber = categoryRuleNumber + 1
        let closing = "\(finalRuleNumber). 禁止编造原文没有的信息。\(Self.languageDirective(preferredLanguage))"

        switch bodyStyle {
        case .modelRewrite:
            return """
            你是 ClipNest 笔记整理器。阅读原文，只返回一个 JSON 对象：
            {"title":"...","summary":"...","content":"...","category":"...","tags":["..."]}

            规则：
            1. title：原文主题，20 字以内，不要使用分类名。
            2. summary：1-3 句，覆盖原文全部要点。
            3. content：把原文完整整理成 Markdown，保留所有要点、代码、数字和 URL，不能只写一两句。
            4. tags：2-5 个关键词，必须是原文里出现过的词，不要使用分类名。
            \(categoryRule)
            \(closing)

            原文：
            \(text)
            """

        case .sourceVerbatim:
            // `content` is absent from the schema *and* explicitly ruled out: naming what must
            // not be produced is what stopped the model adding the field anyway.
            return """
            你是 ClipNest 笔记整理器。阅读原文，只返回一个 JSON 对象：
            {"title":"...","summary":"...","category":"...","tags":["..."]}

            规则：
            1. title：原文主题，20 字以内，不要使用分类名。
            2. summary：1-3 句，覆盖原文全部要点。
            3. tags：2-5 个关键词，必须是原文里出现过的词，不要使用分类名。
            \(categoryRule)
            \(closing)
            \(finalRuleNumber + 1). 不要输出 content 字段，正文由程序保留原文。

            原文：
            \(text)
            """
        }
    }

    /// A single, unambiguous instruction about the output language.
    private static func languageDirective(_ language: PreferredLanguage) -> String {
        switch language {
        case .simplifiedChinese:
            return "请用简体中文输出。"
        case .english:
            return "Write the output in English."
        case .automatic:
            return "使用与原文相同的语言。"
        }
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
