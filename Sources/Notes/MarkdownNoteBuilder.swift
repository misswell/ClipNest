import Foundation

/// Renders a `GeneratedNote` plus the captured source material into the final Markdown.
///
/// The shape is no longer hardcoded (方案 §15, §16): every section exists only when the
/// `NoteFormatConfiguration` asks for it and the material for it exists. Headings are
/// minimal by rule (方案 §16) — a note that is just a title and a body gets no `##` chrome
/// at all; the old behaviour of always appending `## 原始内容` is gone. When the capture
/// itself is a picture, the picture — not its OCR transcription — occupies the source slot.
enum MarkdownNoteBuilder {
    static func make(note: GeneratedNote,
                     originalContent: ClipboardContent,
                     format: NoteFormatConfiguration = .default,
                     attachments: [SavedAttachment] = [],
                     date: Date = Date(),
                     sourceKind: CaptureSourceKind = .clipboard) -> String {
        var lines: [String] = []

        let sourceURL = note.sourceURL ?? originalContent.sourceURL
        if format.includeFrontmatter {
            lines = frontmatter(for: note,
                                sourceURL: format.includeSourceURL ? sourceURL : nil,
                                includeTags: format.includeTags,
                                includeCreatedAt: format.includeCreatedAt,
                                date: date)
        }

        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if format.includeTitle {
            if !lines.isEmpty { lines.append("") }
            lines.append("# \(title.isEmpty ? "Untitled" : title)")
        }

        let summary = format.includeSummary
            ? note.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let originalText = originalContent.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // When the capture *is* a picture (photo or imported file) the OCR text is derived
        // data: the source slot keeps the image itself, not its transcription. A clipboard
        // capture that merely carries an image still keeps its own text as the source, and
        // with image saving turned off the transcription is all there is to keep.
        let embedLines = attachments.map { embedLine(for: $0, style: format.imageLinkStyle) }
        let originalIsImage = sourceKind != .clipboard && !embedLines.isEmpty

        // The body: the model's organized text when the format wants one. When the body slot
        // ends up empty anyway — a provider that answered without its body — the source takes
        // the slot: a title-only note is a worse outcome than the text the user captured. A
        // format that wanted neither a body nor the source (title-only) is honoured as chosen.
        var body = format.generatesBody
            ? note.content.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        var sourceIsInTheBody = false
        if body.isEmpty, format.generatesBody || format.includeOriginalText {
            if originalIsImage {
                body = embedLines.joined(separator: "\n\n")
                sourceIsInTheBody = true
            } else {
                body = originalText
            }
        }

        if !summary.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: ["## 摘要", "", summary])
        }
        if !body.isEmpty {
            if !lines.isEmpty { lines.append("") }
            if summary.isEmpty {
                lines.append(body)
            } else {
                lines.append(contentsOf: ["## 正文", "", body])
            }
        }

        // The embeds are placed exactly once. When the capture is an image the picture *is*
        // the source material, so it renders in the source slot (as the body, or as the
        // section below next to an organized body) instead of being appended here.
        let embedsLiveInTheSourceSlot = originalIsImage
            && (sourceIsInTheBody || format.includeOriginalText)
        if format.includeOriginalImage, !embedsLiveInTheSourceSlot {
            for attachment in attachments {
                if !lines.isEmpty { lines.append("") }
                lines.append(embedLine(for: attachment, style: format.imageLinkStyle))
            }
        }

        // The source is quoted as its own section only when it is *not* already the body —
        // that distinction is what "keep the original text" means next to an organized body
        // (方案 §16). For an image capture the section keeps the picture; the OCR text is
        // derived and is never quoted back as "original".
        if format.includeOriginalText {
            if originalIsImage {
                if !sourceIsInTheBody {
                    if !lines.isEmpty { lines.append("") }
                    lines.append(contentsOf: ["## 原始内容", ""])
                    lines.append(contentsOf: embedLines)
                }
            } else if !originalText.isEmpty,
               originalText != body {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: ["## 原始内容", ""])
                lines.append(contentsOf: quote(originalContent.text))
            }
        }

        // Metadata that would have lived in the frontmatter degrades to inline lines when
        // the frontmatter is off, so turning the frontmatter off never silently drops data.
        if !format.includeFrontmatter {
            if format.includeTags {
                let tags = uniqueTags(note.tags)
                if !tags.isEmpty {
                    if !lines.isEmpty { lines.append("") }
                    lines.append(tags.map { "#\($0)" }.joined(separator: " "))
                }
            }
            if format.includeSourceURL, let sourceURL {
                if !lines.isEmpty { lines.append("") }
                lines.append("<\(sourceURL.absoluteString)>")
            }
        }

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

    /// The vault-relative link for one attachment (方案 §19). Capture notes always sit one
    /// directory below the vault root, so the plain-Markdown style needs the `../` climb;
    /// Obsidian embeds resolve from the vault root on their own.
    private static func embedLine(for attachment: SavedAttachment, style: ImageLinkStyle) -> String {
        let alt = String(localized: "Original image")
        switch style {
        case .markdown:
            return "![\(alt)](../\(attachment.relativePath))"
        case .obsidian:
            return "![[\(attachment.relativePath)]]"
        }
    }

    private static func frontmatter(for note: GeneratedNote,
                                    sourceURL: URL?,
                                    includeTags: Bool,
                                    includeCreatedAt: Bool,
                                    date: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["---"]
        if includeCreatedAt {
            lines.append("created: \(formatter.string(from: date))")
        }
        if includeTags {
            lines.append("tags:")
            let uniqueTags = uniqueTags(note.tags)
            if uniqueTags.isEmpty {
                lines.append("  - ClipNest")
            } else {
                lines.append(contentsOf: uniqueTags.map { "  - \(yamlScalar($0))" })
            }
        }
        lines.append("source: clipboard")
        if let sourceURL {
            lines.append("sourceURL: \(yamlScalar(sourceURL.absoluteString))")
        }
        lines.append("---")
        return lines
    }

    private static func uniqueTags(_ tags: [String]) -> [String] {
        tags.reduce(into: [String]()) { result, tag in
            let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
            else { return }
            result.append(value)
        }
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
