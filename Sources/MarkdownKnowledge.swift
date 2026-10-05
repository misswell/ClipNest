import Foundation

struct NoteLink: Sendable, Equatable {
    let target: String
    let label: String
    let range: NSRange
    let targetRange: NSRange
    let isWiki: Bool
    let isEmbed: Bool
}

struct NoteHeading: Identifiable, Sendable, Equatable {
    let level: Int
    let title: String
    let line: Int
    var id: Int { line }
}

struct NoteKnowledge: Sendable {
    let url: URL
    let links: [NoteLink]
    let headings: [NoteHeading]
    let tags: [String]
    let aliases: [String]
    let properties: [String: String]
    let words: Int
    let characters: Int
    let excerpt: String
    let searchText: String
    let values: [String: CanvasValue]
    let created: Date?
    let modified: Date?
    let fileSize: Int
}

/// Shared syntax for navigation, indexing and link-preserving file operations. Ranges are
/// UTF-16 offsets so replacements never corrupt Chinese text or emoji.
enum MarkdownKnowledge {
    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func proseMask(_ text: String) -> String {
        let ns = text as NSString
        let result = NSMutableString(string: text)
        var offset = 0
        var fence: (Character, Int)?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let char = trimmed.first
            let run = trimmed.prefix(while: { $0 == char }).count
            let marker = (char == "`" || char == "~") && run >= 3
            let closing = marker && fence?.0 == char && run >= (fence?.1 ?? 0)
                && trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
            if fence != nil || marker {
                let length = (line as NSString).length
                result.replaceCharacters(in: NSRange(location: offset, length: length),
                                         with: String(repeating: " ", count: length))
                if fence != nil { if closing { fence = nil } }
                else if let char { fence = (char, run) }
            }
            offset += (line as NSString).length + 1
        }
        for match in matches("(?s)<!--.*?-->|%%.*?%%|(`+)(?!`).*?\\1(?!`)", in: result as String).reversed() {
            result.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        assert(result.length == ns.length)
        return result as String
    }

    static func links(in text: String) -> [NoteLink] {
        let mask = proseMask(text)
        let ns = text as NSString
        var result: [NoteLink] = []
        for match in matches("(?<![\\\\])(!?)\\[\\[([^\\]\\n]+)\\]\\]", in: mask) {
            let contentRange = match.range(at: 2)
            let content = ns.substring(with: contentRange)
            let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(parts[0]).trimmingCharacters(in: .whitespaces)
            result.append(NoteLink(target: target, label: parts.count > 1 ? String(parts[1]) : target,
                                   range: match.range,
                                   targetRange: NSRange(location: contentRange.location,
                                                        length: (String(parts[0]) as NSString).length),
                                   isWiki: true, isEmbed: match.range(at: 1).length > 0))
        }
        for match in matches("(?<![\\\\])(!?)\\[([^\\]\\n]*)\\]\\((<[^>\\n]+>|[^\\s)]+)(?:\\s+\"[^\"\\n]*\")?\\)", in: mask) {
            guard !result.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
            let range = match.range(at: 3)
            var target = ns.substring(with: range)
            var targetRange = range
            if target.hasPrefix("<"), target.hasSuffix(">") {
                target = String(target.dropFirst().dropLast())
                targetRange = NSRange(location: range.location + 1, length: range.length - 2)
            }
            result.append(NoteLink(target: target, label: ns.substring(with: match.range(at: 2)),
                                   range: match.range, targetRange: targetRange,
                                   isWiki: false, isEmbed: match.range(at: 1).length > 0))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    static func frontmatterRange(in text: String) -> NSRange? {
        matches("(?s)\\A(?:\\uFEFF)?---[ \\t]*\\r?\\n.*?\\r?\\n(?:---|\\.\\.\\.)[ \\t]*(?:\\r?\\n|$)", in: text).first?.range
    }

    static func properties(in text: String) -> [String: String] {
        guard let range = frontmatterRange(in: text) else { return [:] }
        let lines = (text as NSString).substring(with: range).components(separatedBy: "\n")
        var result: [String: String] = [:]
        var key: String?
        for line in lines.dropFirst() {
            if let match = matches("^([A-Za-z_][A-Za-z0-9_-]*):[ \\t]*(.*)$", in: line).first {
                let ns = line as NSString
                key = ns.substring(with: match.range(at: 1))
                result[key!] = ns.substring(with: match.range(at: 2))
            } else if line.hasPrefix(" "), let key {
                result[key, default: ""] += "\n" + line
            }
        }
        return result
    }

    static func listValues(_ value: String?) -> [String] {
        guard let value else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            // Split commas outside quotes, including quoted aliases containing commas.
            parts = matches("(?:\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|[^,]+)",
                            in: String(trimmed.dropFirst().dropLast())).map {
                (String(trimmed.dropFirst().dropLast()) as NSString).substring(with: $0.range)
            }
        } else if trimmed.contains("\n") || trimmed.hasPrefix("-") {
            parts = trimmed.components(separatedBy: "\n").map {
                let item = $0.trimmingCharacters(in: .whitespaces)
                return item.hasPrefix("-") ? String(item.dropFirst()) : item
            }
        } else { parts = [trimmed] }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
    }

    static func body(_ text: String) -> String {
        guard let range = frontmatterRange(in: text) else { return text }
        return (text as NSString).substring(from: NSMaxRange(range))
    }

    static func analyze(_ text: String, url: URL) -> NoteKnowledge {
        var properties = properties(in: text)
        let values = (try? NoteProperties.parse(NoteProperties.yaml(text))) ?? [:]
        for (key, value) in values where properties[key] == nil { properties[key] = BaseExpression.display(value) }
        let metadata = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        let mask = proseMask(body(text))
        let headings = mask.components(separatedBy: "\n").enumerated().compactMap { offset, line -> NoteHeading? in
            guard let match = matches("^ {0,3}(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+[ \\t]*)?$", in: line).first else { return nil }
            let ns = line as NSString
            return NoteHeading(level: match.range(at: 1).length,
                               title: ns.substring(with: match.range(at: 2)), line: offset)
        }
        let inlineTags = matches("(?<![\\w/#])#([\\p{L}\\p{N}_/-]+)", in: mask).map {
            (mask as NSString).substring(with: $0.range(at: 1))
        }.filter { $0.contains(where: { $0.isLetter || $0 == "_" || $0 == "/" || $0 == "-" }) }
        let tags = Set(((values["tags"] == nil ? listValues(properties["tags"]) : NoteProperties.strings(values["tags"])) + inlineTags).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }).sorted()
        let content = body(text)
        var words = 0
        content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: .byWords) { _, _, _, _ in words += 1 }
        return NoteKnowledge(url: url, links: links(in: text), headings: headings, tags: tags,
                             aliases: values["aliases"] == nil ? listValues(properties["aliases"]) : NoteProperties.strings(values["aliases"]), properties: properties,
                             words: words, characters: content.count,
                             excerpt: String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)), searchText: mask, values: values,
                             created: metadata?.creationDate, modified: metadata?.contentModificationDate, fileSize: metadata?.fileSize ?? 0)
    }

    static func isExternal(_ target: String) -> Bool {
        target.hasPrefix("//") || matches("^[a-zA-Z][a-zA-Z0-9+.-]*:", in: target).first != nil
    }

    static func splitTarget(_ target: String) -> (path: String, fragment: String) {
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]).removingPercentEncoding ?? String(parts[0]),
                parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : "")
    }

    static func relativePath(_ url: URL, to directory: URL) -> String {
        let a = directory.standardizedFileURL.pathComponents
        let b = url.standardizedFileURL.pathComponents
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + b.dropFirst(common)).joined(separator: "/")
    }

    static func resolve(_ target: String, from document: URL, root: URL,
                        files: [URL], aliases: [String: [URL]] = [:]) -> URL? {
        NoteLinkResolver(root: root, files: files, aliases: aliases).resolve(target, from: document)
    }

    static func navigationURL(_ target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "clipnest-note"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        return components.url
    }

    static func navigationTarget(_ url: URL) -> String? {
        guard url.scheme == "clipnest-note", url.host == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "target" }?.value
    }

    static func renderInline(_ text: String) -> AttributedString {
        let output = NSMutableString(string: text)
        for link in links(in: text).reversed() where !link.isEmbed && !isExternal(link.target) {
            guard let url = navigationURL(link.target) else { continue }
            let label = link.label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            output.replaceCharacters(in: link.range, with: "[\(label)](\(url.absoluteString))")
        }
        return (try? AttributedString(markdown: NoteFootnotes.inline(output as String),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func rewritten(_ text: String, document: URL, root: URL, files: [URL],
                          source: URL, destination: URL, aliases: [String: [URL]] = [:], lookup: NoteLinkResolver? = nil,
                          preserveAliases: Bool = true) -> String {
        let lookup = lookup ?? NoteLinkResolver(root: root, files: files, aliases: aliases)
        let move = VaultDocumentMove(source: source, destination: destination)
        let newDocument = move.relocated(document)
        let output = NSMutableString(string: text)
        for link in links(in: text).reversed() {
            guard let target = lookup.resolve(link.target, from: document) else { continue }
            let newTarget = move.relocated(target)
            let parts = splitTarget(link.target)
            if preserveAliases, link.isWiki, (lookup.names[parts.path.lowercased()] ?? []).isEmpty,
               lookup.aliases[parts.path.lowercased()]?.contains(target) == true { continue }
            guard newTarget != target || newDocument != document else { continue }
            var path = link.isWiki ? relativePath(newTarget, to: root)
                                  : relativePath(newTarget, to: newDocument.deletingLastPathComponent())
            if link.isWiki, (parts.path as NSString).pathExtension.isEmpty,
               FileNode.markdownExtensions.contains(newTarget.pathExtension.lowercased()) {
                path = (path as NSString).deletingPathExtension
            }
            if parts.path.isEmpty && newTarget == newDocument { path = "" }
            if !link.isWiki {
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "#?()")
                path = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
            }
            if !parts.fragment.isEmpty { path += "#" + parts.fragment }
            output.replaceCharacters(in: link.targetRange, with: path)
        }
        return output as String
    }
}
