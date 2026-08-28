import Foundation

enum MarkdownNoteBuilder {
    static func make(note: GeneratedNote,
                     originalContent: ClipboardContent,
                     date: Date = Date()) -> String {
        var lines = frontmatter(for: note,
                                sourceURL: note.sourceURL ?? originalContent.sourceURL,
                                date: date)
        lines.append("")
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("# \(title.isEmpty ? "Untitled" : title)")

        let summary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append(contentsOf: ["", "## 摘要", "", summary])
        }

        let content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            lines.append(contentsOf: ["", "## 内容", "", content])
        } else if !originalContent.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Keep the note useful even if a provider returns no separate body.
            lines.append(contentsOf: ["", "## 内容", "", originalContent.rawText])
        }

        lines.append(contentsOf: ["", "## 原始内容", ""])
        lines.append(contentsOf: quote(originalContent.rawText))
        return lines.joined(separator: "\n") + "\n"
    }

    static func makeRawClipboardNote(content: ClipboardContent,
                                     date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [
            "---",
            "created: \(formatter.string(from: date))",
            "source: clipboard",
            "kind: \(content.kind.rawValue)"
        ]
        if let sourceURL = content.sourceURL {
            lines.append("sourceURL: \(sourceURL.absoluteString)")
        }
        lines.append(contentsOf: ["---", "", "# Clipboard \(rawTitleDateFormatter.string(from: date))", "", "## 原始内容", "", content.rawText, ""])
        return lines.joined(separator: "\n")
    }

    private static func frontmatter(for note: GeneratedNote,
                                    sourceURL: URL?,
                                    date: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["---", "created: \(formatter.string(from: date))", "tags:"]
        let uniqueTags = note.tags.reduce(into: [String]()) { result, tag in
            let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
            else { return }
            result.append(value)
        }
        if uniqueTags.isEmpty {
            lines.append("  - ClipNest")
        } else {
            lines.append(contentsOf: uniqueTags.map { "  - \(yamlScalar($0))" })
        }
        lines.append("source: clipboard")
        if let sourceURL {
            lines.append("sourceURL: \(yamlScalar(sourceURL.absoluteString))")
        }
        lines.append("---")
        return lines
    }

    private static func quote(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { line in
            line.isEmpty ? ">" : "> \(line)"
        }
    }

    private static func yamlScalar(_ value: String) -> String {
        let needsQuotes = value.contains(where: { $0 == ":" || $0 == "#" || $0 == "\"" || $0 == "'" })
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let rawTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}
