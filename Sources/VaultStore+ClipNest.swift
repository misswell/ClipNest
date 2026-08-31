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

struct VaultCategorySummary: Identifiable, Equatable, Sendable {
    let name: String
    let count: Int

    var id: String { name }
}

struct VaultTimelineItem: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date

    var id: URL { url }
}

/// Values needed by the lightweight vault home screen. The URLs are kept in newest-first
/// order so opening a document never has to walk the vault or query file dates again.
struct VaultHomeSnapshot: Equatable, Sendable {
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
        VaultHomeSnapshotBuilder.make(from: node)
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

}

/// Builds the home/timeline metadata without touching the main actor. File dates can be
/// expensive for iCloud-backed vaults, and tens of thousands of metadata reads must not block
/// the navigation or scrolling surfaces.
enum VaultHomeSnapshotBuilder {
    static func make(from node: FileNode) -> VaultHomeSnapshot {
        makeSnapshot(from: node, shouldCancel: { false }) ?? .empty
    }

    static func makeCancellable(from node: FileNode) -> VaultHomeSnapshot? {
        makeSnapshot(from: node, shouldCancel: { Task.isCancelled })
    }

    private static func makeSnapshot(from node: FileNode,
                                     shouldCancel: @Sendable () -> Bool) -> VaultHomeSnapshot? {
        let rootChildren = node.isDirectory ? (node.children ?? []) : [node]
        let topLevelDirectories = node.isDirectory
            ? rootChildren.filter(\.isDirectory)
            : []

        var categoryCounts: [URL: Int] = [:]
        categoryCounts.reserveCapacity(topLevelDirectories.count)
        for directory in topLevelDirectories {
            categoryCounts[directory.url] = 0
        }

        // Walk the existing tree once to collect both dates and category counts. The previous
        // implementation flattened the tree and then traversed every category a second time.
        var pending: [(node: FileNode, categoryURL: URL?)] = []
        pending.reserveCapacity(rootChildren.count)
        for child in rootChildren {
            pending.append((child, child.isDirectory ? child.url : nil))
        }

        var datedFiles: [(url: URL, date: Date)] = []
        datedFiles.reserveCapacity(1024)
        var visited = 0
        while let current = pending.popLast() {
            visited += 1
            if visited.isMultiple(of: 256), shouldCancel() { return nil }

            if current.node.isDirectory {
                for child in current.node.children ?? [] {
                    pending.append((child, current.categoryURL))
                }
                continue
            }
            guard current.node.isMarkdown else { continue }

            let date = (try? current.node.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            datedFiles.append((current.node.url, date))
            if let categoryURL = current.categoryURL {
                categoryCounts[categoryURL, default: 0] += 1
            }
        }

        guard !shouldCancel() else { return nil }
        datedFiles.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        guard !shouldCancel() else { return nil }

        let orderedItems = datedFiles.map { VaultTimelineItem(url: $0.url, date: $0.date) }
        let orderedFiles = orderedItems.map(\.url)
        let inboxPath = node.url
            .appendingPathComponent(ClassificationService.inbox, isDirectory: true)
            .standardizedFileURL
            .path + "/"
        let inboxFile = orderedFiles.first {
            $0.standardizedFileURL.path.hasPrefix(inboxPath)
        }
        let categories = topLevelDirectories.map {
            VaultCategorySummary(name: $0.name, count: categoryCounts[$0.url, default: 0])
        }

        return VaultHomeSnapshot(markdownFiles: orderedFiles,
                                 timelineItems: orderedItems,
                                 inboxFile: inboxFile,
                                 categories: categories)
    }
}
