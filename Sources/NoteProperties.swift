import Foundation
import Yams

enum NoteProperties {
    static func yaml(_ text: String) -> String {
        guard let range = MarkdownKnowledge.frontmatterRange(in: text) else { return "" }
        var lines = (text as NSString).substring(with: range).components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last == "" { lines.removeLast() }
        if !lines.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func parse(_ yaml: String) throws -> [String: CanvasValue] {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard yaml.utf8.count <= 128 * 1024 else { throw VaultAccessError.readFailed(String(localized: "Properties exceed the 128 KB limit.")) }
        let keys = yaml.components(separatedBy: "\n").compactMap(topLevelKey)
        guard Set(keys).count == keys.count else { throw VaultAccessError.readFailed(String(localized: "Remove duplicate property keys before editing.")) }
        let decoder = YAMLDecoder()
        decoder.options.aliasDereferencingStrategy = BasicAliasDereferencingStrategy()
        return try decoder.decode([String: CanvasValue].self, from: yaml)
    }

    static func strings(_ value: CanvasValue?) -> [String] {
        switch value {
        case .array(let values): return values.compactMap(\.string)
        case .string(let value): return [value]
        default: return []
        }
    }

    static func setting(_ value: CanvasValue, key: String, in text: String) throws -> String {
        let original = yaml(text)
        _ = try parse(original)
        var lines = original.components(separatedBy: "\n")
        let encodedKey = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        let encodedValue = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let newLine = encodedKey + ": " + encodedValue
        if let i = lines.firstIndex(where: { topLevelKey($0) == key }) {
            var end = i + 1
            while end < lines.count, topLevelKey(lines[end]) == nil { end += 1 }
            while end > i + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty || lines[end - 1].hasPrefix("#") { end -= 1 }
            let anchor = MarkdownKnowledge.matches(":\\s*(&[A-Za-z0-9_-]+)", in: lines[i]).first.map {
                (lines[i] as NSString).substring(with: $0.range(at: 1)) + " "
            } ?? ""
            lines.replaceSubrange(i..<end, with: [encodedKey + ": " + anchor + encodedValue])
        } else { lines.append(newLine) }
        let replacement = lines.joined(separator: "\n")
        _ = try parse(replacement)
        return "---\n" + replacement + "\n---\n" + MarkdownKnowledge.body(text)
    }

    static func topLevelKey(_ line: String) -> String? {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
              let match = MarkdownKnowledge.matches("^(\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^']|'')*'|[^\\s:#][^:]*):", in: line).first else { return nil }
        let key = (line as NSString).substring(with: match.range(at: 1))
        return (try? YAMLDecoder().decode([String: CanvasValue].self, from: key + ": null"))?.keys.first
    }

    static func encode(_ values: [String: CanvasValue]) throws -> String { try YAMLEncoder().encode(values) }
}
