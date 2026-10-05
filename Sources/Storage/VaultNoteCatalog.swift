import Foundation

enum VaultNoteCatalog {
    /// Foundation may leave a nonexistent final component unresolved. Resolve its nearest
    /// existing ancestor before accepting a creation path through a symlinked directory.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            // A dangling symlink is still an invalid creation ancestor.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { return false }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        let resolved = suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL.path
        return resolved.hasPrefix(rootPath + "/")
    }
    /// Metadata only: opening a vault must not download all its note bodies from iCloud.
    static func files(in root: URL) -> [URL] {
        let root = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if FileNode.indexingExcludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            } else if values.isRegularFile == true { result.append(url.standardizedFileURL) }
        }
        return result.sorted { $0.path < $1.path }
    }
}

struct VaultLinkMutation: Equatable, Sendable {
    let source: URL
    let destination: URL
    let root: URL
    let files: [URL]
    let aliases: [String: [URL]]
    var rewrittenFiles: [URL] = []
    var isMerge = false
    let lookup: NoteLinkResolver

    init(source: URL, destination: URL, root: URL, files: [URL], aliases: [String: [URL]]) {
        self.source = source; self.destination = destination; self.root = root; self.files = files; self.aliases = aliases
        lookup = NoteLinkResolver(root: root, files: files, aliases: aliases)
    }

    func rewrite(_ text: String, at url: URL) -> String {
        MarkdownKnowledge.rewritten(text, document: url, root: root, files: files,
                                    source: source, destination: destination, aliases: aliases, lookup: lookup, preserveAliases: !isMerge)
    }
}

extension VaultFileAccess {
    /// Prepare all changed contents before moving anything. A failed write rolls back the
    /// writes already completed and the filesystem move. Never replaces a concurrent edit.
    nonisolated static func moveUpdatingLinks(at source: URL, to destination: URL, root: URL) throws -> VaultLinkMutation {
        try performMutation {
            let files = VaultNoteCatalog.files(in: root)
            var originals: [URL: Data] = [:]
            var aliases: [String: [URL]] = [:]
            for url in files where FileNode.markdownExtensions.contains(url.pathExtension.lowercased()) || ["canvas", "base"].contains(url.pathExtension.lowercased()) {
                let data = try readDataImmediately(at: url)
                guard let text = String(data: data, encoding: .utf8) else { throw VaultAccessError.notUTF8 }
                originals[url] = data
                let properties = try? NoteProperties.parse(NoteProperties.yaml(text))
                for alias in url.pathExtension.lowercased() == "canvas" ? [] : NoteProperties.strings(properties?["aliases"]) {
                    aliases[alias.lowercased(), default: []].append(url)
                }
            }
            var mutation = VaultLinkMutation(source: source, destination: destination,
                                             root: root, files: files, aliases: aliases)
            let move = VaultDocumentMove(source: source, destination: destination)
            var replacements: [(old: URL, new: URL, original: Data, replacement: Data)] = []
            for (url, data) in originals {
                let text = String(decoding: data, as: UTF8.self)
                let updated: String
                if url.pathExtension.lowercased() == "canvas" {
                    var canvas = try JSONCanvasDocument(text: text)
                    let original = canvas.data
                    canvas.rewriteLinks(using: mutation, at: url)
                    updated = original == canvas.data ? text : try canvas.text()
                } else { updated = mutation.rewrite(text, at: url) }
                if updated != text {
                    if url.pathExtension.lowercased() == "base" { _ = try NoteProperties.parse(updated) }
                    else if MarkdownKnowledge.frontmatterRange(in: text) != nil,
                            (try? NoteProperties.parse(NoteProperties.yaml(text))) != nil {
                        _ = try NoteProperties.parse(NoteProperties.yaml(updated))
                    }
                    replacements.append((url, move.relocated(url), data, Data(updated.utf8)))
                }
            }
            for item in replacements {
                try VaultHistory.record(String(decoding: item.original, as: UTF8.self), for: item.old, root: root)
            }
            for url in originals.keys where move.relocated(url) != url {
                try VaultHistory.relocate(from: url, to: move.relocated(url), root: root)
            }
            try moveItem(at: source, to: destination)
            var written: [(old: URL, new: URL, original: Data, replacement: Data)] = []
            do {
                for item in replacements {
                    guard try readDataImmediately(at: item.new) == item.original else {
                        throw VaultAccessError.writeFailed(String(localized: "A linked note changed during the move. Please retry."))
                    }
                    try writeDataImmediately(item.replacement, to: item.new)
                    written.append(item)
                }
            } catch {
                var rollbackErrors: [String] = []
                for item in written.reversed() {
                    do {
                        guard try readDataImmediately(at: item.new) == item.replacement else {
                            throw VaultAccessError.writeFailed(String(localized: "A linked note changed during rollback."))
                        }
                        try writeDataImmediately(item.original, to: item.new)
                    } catch { rollbackErrors.append(error.localizedDescription) }
                }
                do { try moveItem(at: destination, to: source) }
                catch { rollbackErrors.append(error.localizedDescription) }
                if !rollbackErrors.isEmpty {
                    throw VaultAccessError.writeFailed(error.localizedDescription + "\n" + rollbackErrors.joined(separator: "\n"))
                }
                throw error
            }
            mutation.rewrittenFiles = replacements.map(\.new)
            return mutation
        }
    }
}
