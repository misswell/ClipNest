import Foundation
import CryptoKit

struct NoteVersion: Codable, Identifiable, Sendable {
    let id: String
    let date: Date
    let path: String
    let text: String
}

enum VaultHistory {
    static let limit = 50

    private static func directory(for url: URL, root: URL) -> URL {
        let path = MarkdownKnowledge.relativePath(url, to: root)
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(".clipnest/history/" + key, isDirectory: true)
    }

    static func versions(for url: URL, root: URL) throws -> [NoteVersion] {
        try VaultFileAccess.performMutation {
            let folder = directory(for: url, root: root)
            guard VaultNoteCatalog.isInside(folder, root: root) else {
                throw VaultAccessError.writeFailed(String(localized: "History must remain inside the vault."))
            }
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map {
                    try JSONDecoder().decode(NoteVersion.self, from: VaultFileAccess.readDataImmediately(at: $0))
                }.sorted { $0.date > $1.date }
        }
    }

    static func record(_ text: String, for url: URL, root: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              (FileNode.editableExtensions.contains(url.pathExtension.lowercased()) || ["canvas", "base"].contains(url.pathExtension.lowercased())) else { return }
        try VaultFileAccess.performMutation {
            let existing = try versions(for: url, root: root)
            guard existing.first?.text != text else { return }
            let folder = directory(for: url, root: root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let version = NoteVersion(id: UUID().uuidString, date: Date(),
                                      path: MarkdownKnowledge.relativePath(url, to: root), text: text)
            try VaultFileAccess.writeDataImmediately(JSONEncoder().encode(version),
                                                      to: folder.appendingPathComponent(version.id + ".json"))
            for old in existing.dropFirst(limit - 1) {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(old.id + ".json"))
            }
        }
    }

    /// Restoring in the editor is an explicit action and uses its regular ordered save path.
    static func relocate(from source: URL, to destination: URL, root: URL) throws {
        try VaultFileAccess.performMutation {
            let old = directory(for: source, root: root)
            guard FileManager.default.fileExists(atPath: old.path) else { return }
            let new = directory(for: destination, root: root)
            guard VaultNoteCatalog.isInside(new, root: root) else {
                throw VaultAccessError.writeFailed(String(localized: "History must remain inside the vault."))
            }
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            for version in try versions(for: source, root: root) {
                let relocated = NoteVersion(id: version.id, date: version.date,
                    path: MarkdownKnowledge.relativePath(destination, to: root), text: version.text)
                try VaultFileAccess.writeDataImmediately(JSONEncoder().encode(relocated),
                    to: new.appendingPathComponent(version.id + ".json"))
            }
            // Keep the original history as a recovery copy if subsequent work fails.
        }
    }
}
