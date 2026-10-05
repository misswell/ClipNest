import Foundation

struct NoteLinkResolver: Sendable, Equatable {
    let root: URL
    let known: Set<URL>
    let names: [String: Set<URL>]
    let aliases: [String: [URL]]

    init(root: URL, files: [URL], aliases: [String: [URL]] = [:]) {
        self.root = root.standardizedFileURL
        known = Set(files.map(\.standardizedFileURL))
        self.aliases = aliases
        var names: [String: Set<URL>] = [:]
        for file in files {
            names[file.lastPathComponent.lowercased(), default: []].insert(file)
            names[file.deletingPathExtension().lastPathComponent.lowercased(), default: []].insert(file)
        }
        self.names = names
    }

    func resolve(_ target: String, from document: URL) -> URL? {
        guard !MarkdownKnowledge.isExternal(target) else { return nil }
        let path = MarkdownKnowledge.splitTarget(target).path
        if path.isEmpty { return document }
        for candidate in [document.deletingLastPathComponent().appendingPathComponent(path), root.appendingPathComponent(path)] {
            for url in [candidate, candidate.appendingPathExtension("md")] {
                let normalized = url.standardizedFileURL
                if normalized.path.hasPrefix(root.path + "/"), known.contains(normalized) { return normalized }
            }
        }
        guard !path.contains("/") else { return nil }
        let key = path.lowercased()
        let candidates = names[key] ?? []
        if candidates.count == 1 { return candidates.first }
        if candidates.isEmpty, let matches = aliases[key], matches.count == 1 { return matches[0] }
        return nil
    }
}
