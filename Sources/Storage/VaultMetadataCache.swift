import Foundation

/// Caches the per-file metadata used to order the home / timeline snapshot.
///
/// A full-vault refresh would otherwise issue one `resourceValues(forKeys:)` call per note,
/// which is the dominant cost on a 10,000-file vault. The cache is event-driven: the macOS
/// FSEvents watcher invalidates exactly the paths that changed, and a short TTL bounds
/// staleness if an event is ever missed.
final class VaultMetadataCache: @unchecked Sendable {
    struct Entry: Sendable {
        let modificationDate: Date
        let fileSize: Int
        let checkedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 5) {
        self.ttl = ttl
    }

    func modificationDate(for url: URL, now: Date = Date()) -> Date {
        let path = url.standardizedFileURL.path

        lock.lock()
        if let entry = entries[path], now.timeIntervalSince(entry.checkedAt) < ttl {
            lock.unlock()
            return entry.modificationDate
        }
        lock.unlock()

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0

        lock.lock()
        entries[path] = Entry(modificationDate: date, fileSize: size, checkedAt: now)
        lock.unlock()
        return date
    }

    func invalidate(paths: [String]) {
        guard !paths.isEmpty else { return }
        lock.lock()
        for path in paths {
            entries.removeValue(forKey: URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
