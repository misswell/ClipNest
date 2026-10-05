import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ClipNestVaultError: LocalizedError {
    case noVault
    case cannotCreateFolder
    case cannotWriteNote
    case cannotWriteAttachment

    var errorDescription: String? {
        switch self {
        case .noVault:
            return String(localized: "Open a Markdown vault first.")
        case .cannotCreateFolder:
            return String(localized: "Could not create the target category folder in the vault.")
        case .cannotWriteNote:
            return String(localized: "Could not write the Markdown note. Check vault permissions or disk space.")
        case .cannotWriteAttachment:
            return String(localized: "Could not save the image attachment. Check vault permissions or disk space.")
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

    /// Semantic fingerprints for the local classifier (spec §15): each top-level folder
    /// contributes its name, its immediate sub-folder names, and the titles of the notes it
    /// already holds. Built from the cached home snapshot so classification never walks the
    /// vault again.
    func categoryProfiles(limitPerCategory: Int = 12) -> [CategoryProfile] {
        let names = topLevelCategories()
        guard !names.isEmpty else { return [] }

        var titlesByCategory: [String: [String]] = [:]
        let rootPath = rootURL?.standardizedFileURL.path ?? ""
        for url in homeSnapshot.markdownFiles {
            let components = url.standardizedFileURL.pathComponents
            guard components.count >= 2 else { continue }
            // components: ..., <category>, <file>
            let category = components[components.count - 2]
            guard names.contains(category) else { continue }
            guard titlesByCategory[category, default: []].count < limitPerCategory else { continue }
            titlesByCategory[category, default: []].append(
                url.deletingPathExtension().lastPathComponent)
        }
        _ = rootPath

        return names.map { name in
            CategoryProfile(name: name,
                            keywords: subdirectoryNames(inCategory: name),
                            noteTitles: titlesByCategory[name] ?? [])
        }
    }

    /// Immediate sub-folder names double as curated keywords for a category.
    private func subdirectoryNames(inCategory category: String) -> [String] {
        guard let rootURL else { return [] }
        let directory = rootURL.appendingPathComponent(category, isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
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

    /// Saves a generated note together with its source material (方案 §20, §33).
    ///
    /// One transaction: the attachments and the Markdown file succeed or fail together. The
    /// note path is reserved first, then attachments are written, then the Markdown — and any
    /// failure removes the reserved note file *and* every attachment created by this call, so
    /// a failed capture never leaves orphan files behind.
    func saveGeneratedNote(note: GeneratedNote,
                           captured: CapturedContent,
                           format: NoteFormatConfiguration,
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

        var savedAttachments: [SavedAttachment] = []
        do {
            savedAttachments = try await writeAttachments(captured.images,
                                                          enabled: format.includeOriginalImage,
                                                          rootURL: rootURL)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        // The capture text is guaranteed non-empty by every caller; the placeholder only
        // covers the defensive case of an image-only capture.
        let originalContent = captured.clipboardContent
            ?? ClipboardContent(text: captured.images.isEmpty ? "(empty)" : "(photo)")!
        let markdown = MarkdownNoteBuilder.make(note: note,
                                                originalContent: originalContent,
                                                format: format,
                                                attachments: savedAttachments,
                                                date: date,
                                                sourceKind: captured.sourceKind)
        do {
            try await writeClipNest(markdown, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            rollbackAttachments(savedAttachments)
            throw error
        }
        refresh()
        selectedFileURL = url
        selection.documentSource = .quickPaste
        notifyFileChanges([url])
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
        selection.documentSource = .quickPaste
        notifyFileChanges([url])
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
            try await VaultFileAccess.shared.write(data, to: url)
            noteInternalWrite(to: url)
        } catch {
            throw ClipNestVaultError.cannotWriteNote
        }
    }

    // MARK: - Attachments (方案 §19, §20)

    /// Folder inside the vault that holds images saved with a note.
    static let attachmentsFolder = "Attachments"

    /// Writes the capture's images when the format asks for them, returning the rollback
    /// manifest. Any failure removes the files this call already created.
    private func writeAttachments(_ images: [CapturedImage],
                                  enabled: Bool,
                                  rootURL: URL) async throws -> [SavedAttachment] {
        // Two different concepts (方案 §21): an image can participate in OCR / a vision model
        // and still not be saved. Only `enabled` images ever reach the vault.
        guard enabled, !images.isEmpty else { return [] }

        let directory = rootURL.appendingPathComponent(Self.attachmentsFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        } catch {
            throw ClipNestVaultError.cannotWriteAttachment
        }

        var saved: [SavedAttachment] = []
        for image in images {
            let name = "\(Self.attachmentStamp)-\(UUID().uuidString).\(image.fileExtension)"
            let url = directory.appendingPathComponent(name)
            do {
                try await VaultFileAccess.shared.write(image.data, to: url)
            } catch {
                rollbackAttachments(saved)
                throw ClipNestVaultError.cannotWriteAttachment
            }
            saved.append(SavedAttachment(url: url,
                                         relativePath: "\(Self.attachmentsFolder)/\(name)"))
        }
        return saved
    }

    private func rollbackAttachments(_ attachments: [SavedAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.url)
        }
    }

    /// Local date stamp for attachment file names, e.g. `2026-09-25` (方案 §19).
    private static var attachmentStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
    static func make(from node: FileNode,
                     cache: VaultMetadataCache? = nil) -> VaultHomeSnapshot {
        makeSnapshot(from: node, cache: cache, shouldCancel: { false }) ?? .empty
    }

    static func makeCancellable(from node: FileNode,
                                cache: VaultMetadataCache? = nil) -> VaultHomeSnapshot? {
        makeSnapshot(from: node, cache: cache, shouldCancel: { Task.isCancelled })
    }

    private static func makeSnapshot(from node: FileNode,
                                     cache: VaultMetadataCache?,
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

            let date: Date
            if let cache {
                date = cache.modificationDate(for: current.node.url)
            } else {
                date = (try? current.node.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
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
