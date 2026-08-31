import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ClipNestVaultError: LocalizedError {
    case noVault
    case cannotCreateFolder
    case cannotWriteNote

    var errorDescription: String? {
        switch self {
        case .noVault:
            return String(localized: "Open a Markdown vault first.")
        case .cannotCreateFolder:
            return String(localized: "Could not create the target category folder in the vault.")
        case .cannotWriteNote:
            return String(localized: "Could not write the Markdown note. Check vault permissions or disk space.")
        }
    }
}

struct VaultCategorySummary: Identifiable, Equatable {
    let name: String
    let count: Int

    var id: String { name }
}

struct VaultTimelineItem: Identifiable, Equatable {
    let url: URL
    let date: Date

    var id: URL { url }
}

/// Values needed by the lightweight vault home screen. The URLs are kept in newest-first
/// order so opening a document never has to walk the vault or query file dates again.
struct VaultHomeSnapshot: Equatable {
    let markdownFiles: [URL]
    let timelineItems: [VaultTimelineItem]
    let inboxFile: URL?
    let categories: [VaultCategorySummary]

    static let empty = VaultHomeSnapshot(markdownFiles: [], timelineItems: [], inboxFile: nil, categories: [])
}

@MainActor
extension VaultStore {
    /// Build the home data alongside the tree refresh. Selection changes do not call this.
    func makeHomeSnapshot(from node: FileNode) -> VaultHomeSnapshot {
        let datedFiles = markdownFiles(in: node).map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }
        let orderedItems = datedFiles
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.path.localizedStandardCompare(rhs.0.path) == .orderedAscending
            }
            .map { VaultTimelineItem(url: $0.0, date: $0.1) }
        let orderedFiles = orderedItems.map(\.url)

        let inboxPath = node.url
            .appendingPathComponent(ClassificationService.inbox, isDirectory: true)
            .standardizedFileURL
            .path + "/"
        let inboxFile = orderedFiles.first {
            $0.standardizedFileURL.path.hasPrefix(inboxPath)
        }
        let categories = (node.children ?? [])
            .filter(\.isDirectory)
            .map { VaultCategorySummary(name: $0.name, count: markdownCount(in: $0)) }

        return VaultHomeSnapshot(markdownFiles: orderedFiles,
                                 timelineItems: orderedItems,
                                 inboxFile: inboxFile,
                                 categories: categories)
    }

    /// Reads only immediate child folders. The AI prompt never needs a full Vault content scan.
    func topLevelCategories() -> [String] {
        guard let rootURL else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func categorySummaries() -> [VaultCategorySummary] {
        homeSnapshot.categories
    }

    func recentMarkdownFiles(limit: Int = 10) -> [URL] {
        Array(homeSnapshot.markdownFiles.prefix(max(0, limit)))
    }

    func firstMarkdownFile(inCategory category: String) -> URL? {
        guard let rootURL else { return nil }
        let categoryPath = rootURL
            .appendingPathComponent(category, isDirectory: true)
            .standardizedFileURL
            .path + "/"
        return homeSnapshot.markdownFiles.first {
            $0.standardizedFileURL.path.hasPrefix(categoryPath)
        }
    }

    func saveGeneratedNote(note: GeneratedNote,
                           originalContent: ClipboardContent,
                           date: Date = Date()) async throws -> URL {
        guard let rootURL else { throw ClipNestVaultError.noVault }
        let categoryName = FileNameSanitizer.directoryName(from: note.category,
                                                            fallback: ClassificationService.inbox)
        let directory = rootURL.appendingPathComponent(categoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        } catch {
            throw ClipNestVaultError.cannotCreateFolder
        }

        let baseName = FileNameSanitizer.fileName(from: note.title,
                                                   fallback: "Untitled")
        let url = try reserveUniqueClipNestURL(in: directory, name: baseName + ".md")
        let markdown = MarkdownNoteBuilder.make(note: note,
                                                originalContent: originalContent,
                                                date: date)
        do {
            try await writeClipNest(markdown, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        refresh()
        selectedFileURL = url
        return url
    }

    func saveRawClipboard(_ content: ClipboardContent,
                          date: Date = Date()) async throws -> URL {
        guard let rootURL else { throw ClipNestVaultError.noVault }
        let inbox = rootURL.appendingPathComponent(ClassificationService.inbox, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox,
                                                     withIntermediateDirectories: true)
        } catch {
            throw ClipNestVaultError.cannotCreateFolder
        }

        let fileName = rawClipboardFileName(for: date)
        let url = try reserveUniqueClipNestURL(in: inbox, name: fileName)
        let markdown = MarkdownNoteBuilder.makeRawClipboardNote(content: content, date: date)
        do {
            try await writeClipNest(markdown, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        refresh()
        selectedFileURL = url
        return url
    }

    /// Reserves the path with an exclusive create before the async write begins. This keeps
    /// two capture tasks (or an external file operation) from ever overwriting an existing note.
    private func reserveUniqueClipNestURL(in directory: URL, name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let extensionName = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 1
        while index <= 10_000 {
            #if canImport(Darwin)
            let descriptor = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor >= 0 {
                close(descriptor)
                return candidate
            }
            guard errno == EEXIST else {
                throw ClipNestVaultError.cannotWriteNote
            }
            #else
            if !FileManager.default.fileExists(atPath: candidate.path) {
                FileManager.default.createFile(atPath: candidate.path, contents: nil)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                throw ClipNestVaultError.cannotWriteNote
            }
            #endif
            index += 1
            let suffix = extensionName.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(extensionName)"
            candidate = directory.appendingPathComponent(suffix)
        }
        throw ClipNestVaultError.cannotWriteNote
    }

    private func writeClipNest(_ text: String, to url: URL) async throws {
        let data = Data(text.utf8)
        do {
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: url, options: .atomic)
            }.value
        } catch {
            throw ClipNestVaultError.cannotWriteNote
        }
    }

    private func rawClipboardFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return FileNameSanitizer.fileName(from: formatter.string(from: date), fallback: "Clipboard") + ".md"
    }

    private func markdownCount(in node: FileNode) -> Int {
        if node.isDirectory {
            return node.children?.reduce(0) { $0 + markdownCount(in: $1) } ?? 0
        }
        return node.isMarkdown ? 1 : 0
    }

    private func markdownFiles(in node: FileNode) -> [URL] {
        if node.isDirectory {
            return node.children?.flatMap(markdownFiles(in:)) ?? []
        }
        return node.isMarkdown ? [node.url] : []
    }
}
