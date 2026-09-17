import Foundation

/// Decides whether the model's rewritten body has lost material the prompt told it to keep
/// (China plan §20, §22).
///
/// Measured on the real `Qwen3-0.6B-4bit` weights, the model's body varies run to run: across
/// five samples of the same five-line capture it preserved every fact twice and silently
/// dropped a sentence three times. Two of those drops lost the measurement
/// `iPhone 15 Pro / 0.4 秒`, which is exactly the kind of detail the prompt names as
/// untouchable. A small model cannot be prompted into being reliable about this, so the
/// output is checked instead.
///
/// This is deliberately narrow. It only looks at tokens that carry facts — URLs, numeric
/// literals and technical identifiers — plus a coarse length backstop. Ordinary prose words
/// are not protected, because a legitimate reorganisation is allowed to reword them.
enum LocalFactPreservation {
    /// Below this fraction of the source, a body has not been reorganised, it has been
    /// summarised. Only applied to sources long enough for the ratio to mean something.
    static let minimumBodyRatio = 0.5
    static let minimumSourceLengthForRatio = 240

    /// True when the rewritten body should be rejected in favour of the cleaned source.
    ///
    /// `title` is consulted because a well-formed answer moves the source's H1 into the title
    /// and does not repeat it in the body. Without that, every note whose heading carries a
    /// fact would be judged lossy for a fact that is still present, just filed elsewhere.
    static func losesFacts(modelBody: String, title: String = "", source: String) -> Bool {
        let body = normalized(modelBody)
        let cleanedSource = normalized(source)
        guard !body.isEmpty, !cleanedSource.isEmpty else { return false }

        if !missingProtectedTokens(in: source, body: body + normalized(title)).isEmpty {
            return true
        }

        guard cleanedSource.count >= minimumSourceLengthForRatio else { return false }
        return Double(body.count) < Double(cleanedSource.count) * minimumBodyRatio
    }

    /// The fact-bearing tokens from `source` that do not survive into `body`.
    ///
    /// Exposed separately so a caller (or a test) can say *what* was lost rather than only
    /// that something was.
    static func missingProtectedTokens(in source: String, body: String) -> [String] {
        let body = normalized(body)
        var seen = Set<String>()
        var missing: [String] = []

        for token in protectedTokens(in: source) {
            let key = normalized(token)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard !body.contains(key) else { continue }
            missing.append(token)
        }
        return missing
    }

    /// URLs, numeric literals and technical identifiers found in the text, in document order.
    static func protectedTokens(in text: String) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`。，、；：）】"))
            let key = normalized(token)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            output.append(token)
        }

        for match in Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            // A bare integer that is just a list marker or a sentence number is not a fact;
            // one that is part of a measurement or a version is. Requiring either a decimal
            // part or a unit-ish neighbour keeps `1.` and `2.` out.
            if token.allSatisfy(\.isNumber), token.count <= 2 { continue }
            append(token)
        }

        for term in LocalTextAnalyzer.terms(in: text) where term.isTechnical {
            append(term.text)
        }
        return output
    }

    /// `https://…`, decimals/versions, and Latin identifier runs.
    private static let pattern: NSRegularExpression = {
        // The identifier branch allows a single character before the tail so a hyphenated
        // token such as `zh-Hans` matches whole, instead of degrading to a bare `Hans`.
        let pattern = #"https?://[^\s，。；、）】]+|\d+(?:[.,]\d+)+|[A-Za-z][A-Za-z0-9_]{1,}(?:[._-][A-Za-z0-9]+)*"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Whitespace-insensitive comparison, so a reformatted URL or a wrapped identifier still
    /// counts as present.
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }
}
