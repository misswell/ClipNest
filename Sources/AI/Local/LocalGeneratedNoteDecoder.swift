import Foundation

/// The fields the local model is asked to produce (China plan §20).
struct LocalGeneratedNoteFields: Equatable {
    var title: String
    var summary: String
    var content: String
    var category: String
    var tags: [String]

    static let empty = LocalGeneratedNoteFields(title: "", summary: "", content: "",
                                                category: "", tags: [])
}

/// Tolerant JSON reading for small-model output (China plan §22).
///
/// A 0.6B model routinely wraps JSON in a markdown fence, prefixes it with a sentence, or
/// emits a ` thinking` block first. None of that is a reason to lose a note, so this peels
/// those layers off in order rather than demanding clean JSON.
///
/// The split of responsibility is deliberate:
///
/// - **Structure** failures throw, and the router degrades the whole capture to Local Lite.
/// - **Field** gaps (empty title/content/summary) do *not* throw; the provider repairs them
///   from the source text. Discarding a good rewrite because the model forgot one key would
///   be a worse outcome than filling that key locally.
enum LocalGeneratedNoteDecoder {
    enum DecodingFailure: LocalizedError, Equatable {
        case noJSONObject
        case notAnObject

        var errorDescription: String? {
            switch self {
            case .noJSONObject: return String(localized: "The local model did not return JSON.")
            case .notAnObject: return String(localized: "The local model returned JSON that is not an object.")
            }
        }
    }

    static func decode(_ raw: String) throws -> LocalGeneratedNoteFields {
        let candidates = jsonCandidates(from: raw)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            guard let dictionary = object as? [String: Any] else { continue }
            return fields(from: dictionary)
        }
        // Distinguish "found braces but not an object" from "found nothing", purely so the
        // logged reason is useful.
        if let text = balancedObject(in: strippingThinkBlocks(raw)), !text.isEmpty {
            throw DecodingFailure.notAnObject
        }
        throw DecodingFailure.noJSONObject
    }

    /// Ordered list of strings to try as JSON, cheapest first.
    static func jsonCandidates(from raw: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            out.append(trimmed)
        }

        let ohneReasoning = strippingThinkBlocks(raw)
        add(raw)
        add(ohneReasoning)
        add(strippingCodeFence(raw))
        add(strippingCodeFence(ohneReasoning))
        add(balancedObject(in: raw) ?? "")
        add(balancedObject(in: ohneReasoning) ?? "")

        // Repair pass, tried last so it can never mask a clean answer. See
        // `repairingStrayQuotes` for the measured failure it exists to fix.
        let repaired = repairingStrayQuotes(ohneReasoning)
        if repaired != ohneReasoning {
            add(repaired)
            add(strippingCodeFence(repaired))
            add(balancedObject(in: repaired) ?? "")
        }
        return out
    }

    /// Drops a quote that cannot be opening a string, because the value it would start is
    /// already closed and a `}` or `]` follows it.
    ///
    /// Measured on the real weights with the short prompt: **3 of 20 answers** ended
    /// `...,"tags":["VNRecognizeTextRequest","zh-Hans","accurate"]"}` — one stray quote between
    /// the closing bracket and the closing brace. The text is otherwise perfect, but it is not
    /// JSON, so the whole capture was being thrown away over a single character.
    ///
    /// This runs only after every honest reading has failed, which is what makes the one
    /// imprecision acceptable: a value that genuinely begins with `}` would be misread here,
    /// but such input had already failed to parse by every other route.
    static func repairingStrayQuotes(_ raw: String) -> String {
        let characters = Array(raw)
        var out: [Character] = []
        out.reserveCapacity(characters.count)
        var inString = false
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == "}" || characters[next] == "]" {
                    index += 1          // stray: drop it
                    continue
                }
                inString = true
            }

            out.append(character)
            index += 1
        }
        return String(out)
    }

    /// Removes Qwen-style ` thinking…<｜end▁of▁thinking｜>` blocks, including an unterminated one (the
    /// model hit the token cap mid-reasoning, which means there is no answer at all).
    static func strippingThinkBlocks(_ raw: String) -> String {
        var text = raw
        while let start = text.range(of: " thinking") {
            if let end = text.range(of: "<｜end▁of▁thinking｜>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unwraps ```json … ``` (or a bare ``` fence) when the whole reply is fenced.
    static func strippingCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var body = trimmed.dropFirst(3)
        // Drop an optional language tag on the same line.
        if let newline = body.firstIndex(of: "\n") {
            let tag = body[body.startIndex..<newline]
            if !tag.contains("{") { body = body[body.index(after: newline)...] }
        }
        if let closing = body.range(of: "```", options: .backwards) {
            body = body[body.startIndex..<closing.lowerBound]
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unwraps a `content` field that the model wrapped in a *Markdown* fence.
    ///
    /// Deliberately narrower than `strippingCodeFence`: a note whose body is legitimately a
    /// Swift or SQL listing also starts with ```, and unwrapping that would destroy the very
    /// code the prompt tells the model to preserve. Only `markdown` / `md` / untagged wrappers
    /// are removed.
    static func strippingOuterMarkdownFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        let afterFence = trimmed.dropFirst(3)
        guard let newline = afterFence.firstIndex(of: "\n") else { return trimmed }
        let tag = afterFence[afterFence.startIndex..<newline]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard tag.isEmpty || tag == "markdown" || tag == "md" else { return trimmed }

        let inner = afterFence[afterFence.index(after: newline)...]
        guard let closing = inner.range(of: "```", options: .backwards) else { return trimmed }
        // Anything after the closing fence would be truncated by unwrapping, so only take the
        // wrapper off when the fence really is the outer container.
        let trailing = inner[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty else { return trimmed }

        return inner[inner.startIndex..<closing.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first balanced `{…}`, honouring string literals and escapes so a brace inside a
    /// string cannot end the scan early. This is what makes "here is the JSON: {…} hope
    /// that helps" work.
    static func balancedObject(in raw: String) -> String? {
        let characters = Array(raw)
        guard let start = characters.firstIndex(of: "{") else { return nil }

        var depth = 0
        var index = start
        var inString = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(characters[start...index])
                    }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Field extraction

    static func fields(from dictionary: [String: Any]) -> LocalGeneratedNoteFields {
        LocalGeneratedNoteFields(
            title: string(dictionary, keys: ["title", "标题"]),
            summary: string(dictionary, keys: ["summary", "摘要"]),
            content: string(dictionary, keys: ["content", "body", "正文", "内容"]),
            category: string(dictionary, keys: ["category", "分类"]),
            tags: tags(from: dictionary["tags"] ?? dictionary["标签"] ?? dictionary["keywords"])
        )
    }

    /// Accepts the first key that carries a usable value, including the Chinese keys a
    /// model sometimes reaches for when the prompt is in Chinese.
    private static func string(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let text = value as? String { return normalize(text) }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return ""
    }

    /// `["a","b"]`, `"a, b"` and `"a、b"` are all accepted: the model has one job and
    /// arguing about the container type is not it.
    static func tags(from value: Any?) -> [String] {
        var raw: [String] = []
        switch value {
        case let array as [Any]:
            raw = array.compactMap { item in
                if let text = item as? String { return text }
                if let number = item as? NSNumber { return number.stringValue }
                return nil
            }
        case let text as String:
            raw = text
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .split(whereSeparator: { ",，、;；|/".contains($0) })
                .map(String.init)
        default:
            break
        }

        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            let cleaned = normalize(tag)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*-• \t"))
            guard !cleaned.isEmpty else { continue }
            guard seen.insert(cleaned.lowercased()).inserted else { continue }
            out.append(cleaned)
        }
        return Array(out.prefix(maximumTags))
    }

    /// Spec §13/§20: 2–6 tags. The prompt asks for 2–5; the cap is the outer bound.
    static let maximumTags = 6

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
