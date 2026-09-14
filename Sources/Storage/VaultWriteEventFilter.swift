import Foundation

/// Decides whether a batch of file-system events was caused by the app's own save or by
/// something external (an agent, git, Finder, another editor).
///
/// On a large vault every autosave used to trigger a full tree + metadata rebuild, because
/// FSEvents cannot tell the app's own atomic write apart from an external change. Recording
/// the writes we perform lets that self-inflicted event be dropped, so a 10,000-note vault no
/// longer re-scans itself 600 ms after the user stops typing.
struct VaultWriteEventFilter {
    static let defaultWindow: TimeInterval = 8

    private(set) var internalWrites: [String: Date] = [:]
    var window: TimeInterval = defaultWindow

    /// Records a write the app performed itself, for the file and its directory.
    mutating func noteWrite(to url: URL, at date: Date = Date()) {
        let fileURL = url.standardizedFileURL
        internalWrites[fileURL.path] = date
        internalWrites[fileURL.deletingLastPathComponent().path] = date
        prune(now: date)
    }

    /// True when every reported path is either a file the app just wrote or a scratch file
    /// left behind by its atomic write.
    func isSelfWriteNoise(
        paths: [String],
        now: Date = Date(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard !paths.isEmpty else { return false }
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if let writtenAt = internalWrites[url.path], now.timeIntervalSince(writtenAt) < window {
                continue
            }
            // `Data.write(options: .atomic)` stages a temporary file next to the destination and
            // renames it into place. That scratch path was never recorded, but it is gone again
            // by the time the event is delivered.
            let directory = url.deletingLastPathComponent().path
            if let writtenAt = internalWrites[directory], now.timeIntervalSince(writtenAt) < window,
               !fileExists(path) || url.lastPathComponent.hasPrefix(".") {
                continue
            }
            return false
        }
        return true
    }

    private mutating func prune(now: Date) {
        internalWrites = internalWrites.filter { now.timeIntervalSince($0.value) < window }
    }
}
