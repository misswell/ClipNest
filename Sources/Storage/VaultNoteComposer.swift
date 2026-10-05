import Foundation

enum VaultNoteComposer {
    static func rebase(_ text: String, from source: URL, to destination: URL, root: URL, files: [URL]) -> String {
        let output = NSMutableString(string: text)
        let lookup = NoteLinkResolver(root: root, files: files)
        for link in MarkdownKnowledge.links(in: text).reversed() {
            guard let target = lookup.resolve(link.target, from: source) else { continue }
            let parts = MarkdownKnowledge.splitTarget(link.target)
            var path = MarkdownKnowledge.relativePath(target, to: link.isWiki ? root : destination.deletingLastPathComponent())
            if link.isWiki {
                if (parts.path as NSString).pathExtension.isEmpty, FileNode.markdownExtensions.contains(target.pathExtension.lowercased()) {
                    path = (path as NSString).deletingPathExtension
                }
            } else {
                var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "#?()")
                path = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
            }
            if !parts.fragment.isEmpty { path += "#" + parts.fragment }
            output.replaceCharacters(in: link.targetRange, with: path)
        }
        return output as String
    }

    static func merge(source: URL, destination: URL, root: URL, expectedSource: String) throws -> VaultLinkMutation {
        try VaultFileAccess.performMutation {
            guard source != destination, VaultNoteCatalog.isInside(source, root: root),
                  VaultNoteCatalog.isInside(destination, root: root),
                  FileNode.markdownExtensions.contains(source.pathExtension.lowercased()),
                  FileNode.markdownExtensions.contains(destination.pathExtension.lowercased()) else { throw CocoaError(.fileWriteInvalidFileName) }
            let files = VaultNoteCatalog.files(in: root)
            var originals: [URL: String] = [:]
            var aliases: [String: [URL]] = [:]
            for url in files where FileNode.markdownExtensions.contains(url.pathExtension.lowercased()) || ["canvas", "base"].contains(url.pathExtension.lowercased()) {
                let data = try VaultFileAccess.readDataImmediately(at: url)
                guard let text = String(data: data, encoding: .utf8) else { throw VaultAccessError.notUTF8 }
                originals[url] = text
                let properties = try? NoteProperties.parse(NoteProperties.yaml(text))
                for alias in NoteProperties.strings(properties?["aliases"]) {
                    aliases[alias.lowercased(), default: []].append(url)
                }
            }
            guard originals[source] == expectedSource, let target = originals[destination] else {
                throw VaultAccessError.writeFailed(String(localized: "The note changed. Reload it before composing notes."))
            }
            let oldHeadings = Set(MarkdownKnowledge.analyze(expectedSource, url: source).headings.map { $0.title.lowercased() })
            let newHeadings = Set(MarkdownKnowledge.analyze(target, url: destination).headings.map { $0.title.lowercased() })
            guard oldHeadings.isDisjoint(with: newHeadings) else {
                throw VaultAccessError.writeFailed(String(localized: "Rename duplicate headings before merging to preserve heading links."))
            }
            var mutation = VaultLinkMutation(source: source, destination: destination, root: root, files: files, aliases: aliases)
            mutation.isMerge = true
            let rebased = rebase(expectedSource, from: source, to: destination, root: root, files: files)
            let merged = TemplateInsertion.insert(rebased, into: target + "\n\n")
            var changes: [URL: String] = [:]
            for (url, text) in originals where url != source {
                let input = url == destination ? merged : text
                let output: String
                if url.pathExtension == "canvas" {
                    var canvas = try JSONCanvasDocument(text: input)
                    let previous = canvas.data
                    canvas.rewriteLinks(using: mutation, at: url)
                    output = canvas.data == previous ? input : try canvas.text()
                } else { output = mutation.rewrite(input, at: url) }
                if output != text {
                    if url.pathExtension.lowercased() == "base" { _ = try NoteProperties.parse(output) }
                    else if MarkdownKnowledge.frontmatterRange(in: output) != nil { _ = try NoteProperties.parse(NoteProperties.yaml(output)) }
                    changes[url] = output
                }
            }
            try commit(changes, originals: originals, root: root) {
                guard try VaultTrash.moveToTrash(source, in: root) != nil else { throw CocoaError(.fileWriteUnknown) }
            }
            mutation.rewrittenFiles = Array(changes.keys)
            return mutation
        }
    }

    static func extract(source: URL, destination: URL, root: URL, text: String, heading: NoteHeading) throws -> String {
        try VaultFileAccess.performMutation {
            guard VaultNoteCatalog.isInside(source, root: root), VaultNoteCatalog.isInside(destination, root: root),
                  !FileManager.default.fileExists(atPath: destination.path),
                  FileNode.markdownExtensions.contains(destination.pathExtension.lowercased()) else { throw CocoaError(.fileWriteFileExists) }
            let original = try VaultFileAccess.readDataImmediately(at: source)
            guard String(data: original, encoding: .utf8) == text else {
                throw VaultAccessError.writeFailed(String(localized: "The note changed. Reload it before composing notes."))
            }
            let body = MarkdownKnowledge.body(text)
            var lines = body.components(separatedBy: "\n")
            let headings = MarkdownKnowledge.analyze(text, url: source).headings
            guard headings.contains(heading), heading.line < lines.count else { throw CocoaError(.fileReadCorruptFile) }
            let end = headings.first { $0.line > heading.line && $0.level <= heading.level }?.line ?? lines.count
            let section = lines[heading.line..<end].joined(separator: "\n")
            let extracted = rebase(section, from: source, to: destination, root: root, files: VaultNoteCatalog.files(in: root))
            let path = (MarkdownKnowledge.relativePath(destination, to: root) as NSString).deletingPathExtension
            lines.replaceSubrange(heading.line..<end, with: ["[[" + path + "]]", ""])
            let prefix = MarkdownKnowledge.frontmatterRange(in: text).map { (text as NSString).substring(with: $0) } ?? ""
            let replacement = prefix + lines.joined(separator: "\n")
            try VaultHistory.record(text, for: source, root: root)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VaultFileAccess.createText(extracted, at: destination)
            do { try VaultFileAccess.writeDataImmediately(Data(replacement.utf8), to: source) }
            catch { try FileManager.default.removeItem(at: destination); throw error }
            return replacement
        }
    }

    private static func commit(_ changes: [URL: String], originals: [URL: String], root: URL, completion: () throws -> Void) throws {
        for url in changes.keys { try VaultHistory.record(originals[url]!, for: url, root: root) }
        var written: [URL] = []
        do {
            for (url, text) in changes {
                guard String(data: try VaultFileAccess.readDataImmediately(at: url), encoding: .utf8) == originals[url] else {
                    throw VaultAccessError.writeFailed(String(localized: "A linked note changed during the move. Please retry."))
                }
                try VaultFileAccess.writeDataImmediately(Data(text.utf8), to: url)
                written.append(url)
            }
            try completion()
        } catch {
            var failures: [String] = []
            for url in written {
                do {
                    guard String(data: try VaultFileAccess.readDataImmediately(at: url), encoding: .utf8) == changes[url] else {
                        throw VaultAccessError.writeFailed(String(localized: "A linked note changed during rollback."))
                    }
                    try VaultFileAccess.writeDataImmediately(Data(originals[url]!.utf8), to: url)
                } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { throw VaultAccessError.writeFailed(error.localizedDescription + "\n" + failures.joined(separator: "\n")) }
            throw error
        }
    }
}
