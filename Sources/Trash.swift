import Foundation

struct TrashEntry: Codable, Equatable, Identifiable {
    let id: String                     // file name inside the .trash folder
    let originalRelativePath: String   // path relative to the vault root
    let displayName: String
    let isDirectory: Bool
    let deletedAt: Date
}

/// Vault-internal recycle bin (Obsidian-compatible `.trash` folder). Deleted files and
/// folders are moved here with a manifest, so mistakes can be restored or purged later.
/// The folder is dot-prefixed, so the explorer tree hides it unless hidden files are shown.
enum VaultTrash {
    static let directoryName = ".trash"
    static let autoPurgeInterval: TimeInterval = 30 * 24 * 60 * 60

    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(rootPath + "/")
    }

    static func directoryURL(in root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func manifestURL(in root: URL) -> URL {
        directoryURL(in: root).appendingPathComponent("manifest.json")
    }

    static func loadManifest(in root: URL) -> [TrashEntry] {
        guard let data = try? Data(contentsOf: manifestURL(in: root)) else { return [] }
        return (try? JSONDecoder().decode([TrashEntry].self, from: data)) ?? []
    }

    static func saveManifest(_ entries: [TrashEntry], in root: URL) {
        try? FileManager.default.createDirectory(at: directoryURL(in: root),
                                                  withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: manifestURL(in: root), options: .atomic)
        }
    }

    /// Moves an item from the vault into the trash. Returns nil when the item is not
    /// part of the vault (callers fall back to a plain delete in that case).
    @discardableResult
    static func moveToTrash(_ url: URL, in root: URL) throws -> TrashEntry? {
        guard isInside(url, root: root) else { return nil }
        try FileManager.default.createDirectory(at: directoryURL(in: root),
                                                 withIntermediateDirectories: true)

        let isDirectory = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
        let stamp = Int(Date().timeIntervalSince1970)
        var trashedName = "\(stamp)-\(url.lastPathComponent)"
        var destination = directoryURL(in: root).appendingPathComponent(trashedName)
        var bump = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            trashedName = "\(stamp)-\(bump)-\(url.lastPathComponent)"
            destination = directoryURL(in: root).appendingPathComponent(trashedName)
            bump += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)

        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        let relativePath = fullPath.hasPrefix(rootPath + "/")
            ? String(fullPath.dropFirst(rootPath.count + 1))
            : url.lastPathComponent

        var entries = loadManifest(in: root)
        let entry = TrashEntry(id: trashedName,
                               originalRelativePath: relativePath,
                               displayName: url.lastPathComponent,
                               isDirectory: isDirectory,
                               deletedAt: Date())
        entries.insert(entry, at: 0)
        saveManifest(entries, in: root)
        return entry
    }

    /// Manifest entries whose trashed file still exists on disk.
    static func existingEntries(in root: URL) -> [TrashEntry] {
        loadManifest(in: root).filter {
            FileManager.default.fileExists(atPath: directoryURL(in: root).appendingPathComponent($0.id).path)
        }
    }

    /// Moves a trashed item back to its original location. If something now occupies
    /// that path, the restored copy gets a " 2", " 3" … suffix instead.
    static func restore(_ entry: TrashEntry, in root: URL) throws {
        let source = directoryURL(in: root).appendingPathComponent(entry.id)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var destination = root.standardizedFileURL.appendingPathComponent(entry.originalRelativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            let directory = destination.deletingLastPathComponent()
            let name = destination.lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var bump = 2
            repeat {
                let candidate = ext.isEmpty ? "\(base) \(bump)" : "\(base) \(bump).\(ext)"
                destination = directory.appendingPathComponent(candidate)
                bump += 1
            } while FileManager.default.fileExists(atPath: destination.path)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)

        var entries = loadManifest(in: root)
        entries.removeAll { $0.id == entry.id }
        saveManifest(entries, in: root)
    }

    static func purge(_ entry: TrashEntry, in root: URL) throws {
        let source = directoryURL(in: root).appendingPathComponent(entry.id)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.removeItem(at: source)
        }
        var entries = loadManifest(in: root)
        entries.removeAll { $0.id == entry.id }
        saveManifest(entries, in: root)
    }

    static func purgeAll(in root: URL) throws {
        for entry in loadManifest(in: root) {
            try? FileManager.default.removeItem(at: directoryURL(in: root).appendingPathComponent(entry.id))
        }
        try? FileManager.default.removeItem(at: manifestURL(in: root))
    }

    /// Drops trashed items older than the cutoff (30-day retention policy).
    static func purgeOlderThan(_ cutoff: Date, in root: URL) {
        var entries = loadManifest(in: root)
        let survivors = entries.filter { entry in
            if entry.deletedAt >= cutoff { return true }
            try? FileManager.default.removeItem(at: directoryURL(in: root).appendingPathComponent(entry.id))
            return false
        }
        if survivors.count != entries.count {
            saveManifest(survivors, in: root)
        }
    }
}
