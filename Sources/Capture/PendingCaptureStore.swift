import Foundation

/// One queued capture request. Jobs are persisted so a capture that was interrupted
/// (app quit mid-request, network failure) is retried automatically on the next launch.
struct PendingCapture: Codable, Equatable {
    let hash: String          // content hash; also the dedupe/remove key
    let rawText: String
    let source: String        // "clipboard" | "photo"
    let createdAt: Date
}

enum PendingCaptureStore {
    static let storageKey = "capture.pendingQueue"

    static func load() -> [PendingCapture] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PendingCapture].self, from: data)) ?? []
    }

    static func save(_ captures: [PendingCapture]) {
        let data = try? JSONEncoder().encode(captures)
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Adds a job unless the same content is already queued.
    static func add(hash: String, rawText: String, source: String) {
        var queue = load()
        guard !queue.contains(where: { $0.hash == hash }) else { return }
        queue.append(PendingCapture(hash: hash,
                                    rawText: rawText,
                                    source: source,
                                    createdAt: Date()))
        save(queue)
    }

    static func remove(hash: String) {
        var queue = load()
        queue.removeAll { $0.hash == hash }
        save(queue)
    }

    static func removeAll() {
        save([])
    }
}
