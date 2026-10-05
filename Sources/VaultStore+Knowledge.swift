import Foundation

enum NoteTemplate {
    static func expand(_ template: String, title: String, date: Date = Date()) -> String {
        let output = NSMutableString(string: template)
        for match in MarkdownKnowledge.matches("\\{\\{(title|date|time)(?::([^}]+))?\\}\\}", in: template).reversed() {
            let ns = template as NSString
            let variable = ns.substring(with: match.range(at: 1))
            let value: String
            if variable == "title" { value = title }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = match.range(at: 2).location != NSNotFound
                    ? ns.substring(with: match.range(at: 2)) : variable == "date" ? "yyyy-MM-dd" : "HH:mm"
                formatter.dateFormat = NoteLibrarySettings.compatibleDateFormat(formatter.dateFormat)
                value = formatter.string(from: date)
            }
            output.replaceCharacters(in: match.range, with: value)
        }
        return output as String
    }
}

extension VaultStore {
    func openDailyNote(date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = NoteLibrarySettings.compatibleDateFormat(NoteLibrarySettings.dailyFormat)
        let title = formatter.string(from: date)
        var text = "# " + title + "\n\n"
        if !NoteLibrarySettings.dailyTemplate.isEmpty, let root = rootURL {
            let templateURL = root.appendingPathComponent(NoteLibrarySettings.dailyTemplate).standardizedFileURL
            guard VaultNoteCatalog.isInside(templateURL, root: root) else {
                operationError = String(localized: "Enter a relative note path inside this vault.")
                return
            }
            do {
                let data = try VaultFileAccess.readDataImmediately(at: templateURL)
                guard let template = String(data: data, encoding: .utf8) else { throw VaultAccessError.notUTF8 }
                text = NoteTemplate.expand(template, title: title, date: date)
            } catch { operationError = error.localizedDescription; return }
        }
        let folder = NoteLibrarySettings.dailyFolder
        openOrCreateNote(path: (folder.isEmpty ? "" : folder + "/") + title + ".md", text: text)
    }

    @discardableResult
    func openOrCreateNote(path: String, text: String? = nil) -> URL? {
        guard let root = rootURL else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
            && !$0.contains(":") && !$0.contains("\\")
            && !$0.contains(where: { "[]|#^".contains($0) })
            && $0.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) }) else {
            operationError = String(localized: "Enter a relative note path inside this vault.")
            return nil
        }
        var url = root.appendingPathComponent(path).standardizedFileURL
        if url.pathExtension.isEmpty { url.appendPathExtension("md") }
        guard (FileNode.markdownExtensions.contains(url.pathExtension.lowercased()) || ["canvas", "base"].contains(url.pathExtension.lowercased())),
              VaultNoteCatalog.isInside(url, root: root) else {
            operationError = String(localized: "Enter a relative note path inside this vault.")
            return nil
        }
        do {
            try VaultFileAccess.performMutation {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let title = url.deletingPathExtension().lastPathComponent
                    let initial = url.pathExtension == "canvas" ? "{\"nodes\": [], \"edges\": []}" : url.pathExtension == "base"
                        ? "filters: 'file.ext == \"md\"'\nviews:\n  - type: table\n    name: Notes\n    order:\n      - file.name\n      - note.tags\n" : "# " + title + "\n\n"
                    try VaultFileAccess.createText(text ?? initial, at: url)
                }
            }
            refresh()
            selectedFileURL = url
            notifyFileChanges([url])
            return url
        } catch { operationError = error.localizedDescription; return nil }
    }

    func resolveNote(_ target: String, from url: URL) async -> URL? {
        guard let root = rootURL, !MarkdownKnowledge.isExternal(target) else { return nil }
        knowledge.attach(root)
        let files = await Task.detached(priority: .utility) { VaultNoteCatalog.files(in: root) }.value
        guard rootURL == root else { return nil }
        if let resolved = MarkdownKnowledge.resolve(target, from: url, root: root, files: files, aliases: knowledge.aliases) { return resolved }
        // Aliases live in note properties; opening a link must work before the hub is visited.
        await knowledge.waitUntilLoaded()
        guard rootURL == root, !Task.isCancelled else { return nil }
        return MarkdownKnowledge.resolve(target, from: url, root: root, files: files, aliases: knowledge.aliases)
    }
}
