import SwiftUI

enum NoteLibrarySettings {
    static func compatibleDateFormat(_ format: String) -> String {
        let output = NSMutableString(string: format)
        let tokens = ["YYYY": "yyyy", "YY": "yy", "DD": "dd", "D": "d", "dddd": "EEEE", "ddd": "EEE", "A": "a"]
        for match in MarkdownKnowledge.matches("\\[[^\\]]+\\]|'[^']*'|YYYY|YY|DD|D|dddd|ddd|A", in: format).reversed() {
            let token = (format as NSString).substring(with: match.range)
            let replacement = token.hasPrefix("[") ? "'" + token.dropFirst().dropLast().replacingOccurrences(of: "'", with: "''") + "'" : tokens[token] ?? token
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return output as String
    }
    static var templateFolder: String { UserDefaults.standard.string(forKey: "notes.templateFolder") ?? "Templates" }
    static var dailyFolder: String { UserDefaults.standard.string(forKey: "notes.dailyFolder") ?? "Daily" }
    static var dailyFormat: String { UserDefaults.standard.string(forKey: "notes.dailyFormat") ?? "yyyy-MM-dd" }
    static var dailyTemplate: String { UserDefaults.standard.string(forKey: "notes.dailyTemplate") ?? "" }
}

struct NoteLibrarySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notes.templateFolder") private var templates = "Templates"
    @AppStorage("notes.dailyFolder") private var daily = "Daily"
    @AppStorage("notes.dailyFormat") private var format = "yyyy-MM-dd"
    @AppStorage("notes.dailyTemplate") private var template = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Templates") {
                    TextField("Template folder", text: $templates)
                    Text("Variables: {{title}}, {{date}}, {{time}}, {{date:yyyy-MM-dd}}")
                        .font(.caption).foregroundStyle(Theme.mutedInk)
                }
                Section("Daily Notes") {
                    TextField("Daily note folder", text: $daily)
                    TextField("Date format", text: $format)
                    TextField("Template path (optional)", text: $template)
                    Text("Paths are relative to the vault. Existing daily notes are opened without being overwritten.")
                        .font(.caption).foregroundStyle(Theme.mutedInk)
                }
                Section("File Recovery") {
                    Text("Up to 50 previous versions per note are saved locally in .clipnest/history. They remain in your vault.")
                        .font(.caption)
                }
            }
            .navigationTitle("Note Library Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

enum NoteSearchQuery {
    static func matches(_ query: String, note: NoteKnowledge, root: URL?) -> Bool {
        let path = root.map { MarkdownKnowledge.relativePath(note.url, to: $0) } ?? note.url.lastPathComponent
        let fields = [path, note.aliases.joined(separator: " "), note.tags.joined(separator: " "),
                      note.properties.values.joined(separator: " "), note.searchText].joined(separator: "\n").lowercased()
        let tokens = MarkdownKnowledge.matches("(?:[^\\s\"]*\"[^\"]+\"|[^\\s]+)", in: query).map {
            (query as NSString).substring(with: $0.range)
        }
        return tokens.allSatisfy { token in
            let excluded = token.hasPrefix("-")
            let value = (excluded ? String(token.dropFirst()) : token).replacingOccurrences(of: "\"", with: "").lowercased()
            let result: Bool
            if value.hasPrefix("tag:") {
                let tag = String(value.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                result = note.tags.contains { $0.lowercased() == tag || $0.lowercased().hasPrefix(tag + "/") }
            } else if value.hasPrefix("path:") { result = path.lowercased().contains(value.dropFirst(5)) }
            else if value.hasPrefix("file:") { result = note.url.lastPathComponent.lowercased().contains(value.dropFirst(5)) }
            else if value.hasPrefix("property:") {
                let pair = value.dropFirst(9).split(separator: "=", maxSplits: 1)
                result = pair.first.map { key in note.properties.contains { field in
                    field.key.lowercased() == key && (pair.count < 2 || field.value.lowercased().contains(pair[1]))
                } } ?? false
            } else { result = fields.contains(value) }
            return excluded ? !result : result
        }
    }
}

enum TemplateInsertion {
    static func replacingProperties(in text: String, yaml: String) throws -> String {
        guard !yaml.components(separatedBy: .newlines).contains(where: {
            ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces))
        }) else { throw VaultAccessError.writeFailed(String(localized: "Enter properties without YAML delimiters.")) }
        let header = yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "---\n" + yaml + "\n---\n"
        _ = try NoteProperties.parse(yaml)
        return header + MarkdownKnowledge.body(text)
    }

    static func insert(_ template: String, into text: String) -> String {
        guard let templateRange = MarkdownKnowledge.frontmatterRange(in: template) else {
            return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + template
        }
        guard let existingRange = MarkdownKnowledge.frontmatterRange(in: text) else {
            let header = (template as NSString).substring(with: templateRange)
            return header + text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + MarkdownKnowledge.body(template)
        }
        let existing = (try? NoteProperties.parse(NoteProperties.yaml(text))) ?? [:]
        let header = (template as NSString).substring(with: templateRange)
        let lines = header.components(separatedBy: "\n")
        var chunks: [(key: String, lines: [String])] = []
        for line in lines.dropFirst() {
            if line == "---" || line == "..." { break }
            if let key = NoteProperties.topLevelKey(line) {
                chunks.append((key, [line]))
            } else if !chunks.isEmpty { chunks[chunks.count - 1].lines.append(line) }
        }
        var existingHeader = (text as NSString).substring(with: existingRange).components(separatedBy: "\n")
        if existingHeader.last == "" { existingHeader.removeLast() }
        existingHeader.removeLast()
        for chunk in chunks where existing[chunk.key] == nil { existingHeader += chunk.lines }
        existingHeader += ["---", ""]
        let body = MarkdownKnowledge.body(text)
        return existingHeader.joined(separator: "\n") + body + (body.isEmpty || body.hasSuffix("\n") ? "" : "\n") + MarkdownKnowledge.body(template)
    }
}
