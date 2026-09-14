import Foundation

/// Where a document read currently is. Drives the explicit loading UI so an iCloud
/// placeholder never resolves to a blank editor.
enum DocumentLoadState: Equatable {
    case idle
    case downloading
    case reading
    case ready
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// Progress callback phases reported while a vault file is being made readable/writable.
enum VaultAccessPhase: Sendable, Equatable {
    case downloading
    case reading
    case writing
}

/// Failures surfaced by `VaultFileAccess`. Each case carries a message that is safe to show
/// directly in the editor's failure state.
enum VaultAccessError: LocalizedError {
    case iCloudDownloadFailed(String)
    case iCloudDownloadTimedOut
    case readFailed(String)
    case writeFailed(String)
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .iCloudDownloadFailed(let detail):
            return String(localized: "Could not download this note from iCloud. \(detail)")
        case .iCloudDownloadTimedOut:
            return String(localized: "The note has not finished downloading from iCloud. Check your connection and try again.")
        case .readFailed(let detail):
            return String(localized: "Could not read this note. \(detail)")
        case .writeFailed(let detail):
            return String(localized: "Could not save this note. \(detail)")
        case .notUTF8:
            return String(localized: "This file is not valid UTF-8 text.")
        }
    }
}

/// The single gateway for every byte of vault file I/O.
///
/// Two rules make this the only safe place to touch user notes:
///
/// 1. **iCloud materialisation is explicit and async.** A dataless placeholder in an Obsidian
///    vault inside iCloud Drive must be requested and awaited with `Task.sleep` so the wait is
///    cancellable and never blocks a thread for 30 seconds.
/// 2. **Every read and write goes through `NSFileCoordinator`.** These URLs can be
///    security-scoped folders the user picked in the document picker, where Apple requires
///    coordinated access. Coordinating also serialises us against other editors writing the
///    same note.
///
/// The actor holds the per-path write revision so an older debounced save can never land after
/// a newer one, even though both are dispatched asynchronously.
actor VaultFileAccess {
    static let shared = VaultFileAccess()

    /// Coordinated I/O is blocking by design; keep it off the cooperative pool so a slow
    /// iCloud-backed directory cannot starve unrelated async work.
    private static let coordinationQueue = DispatchQueue(
        label: "com.clipnest.vault.coordination",
        qos: .utility,
        attributes: .concurrent)

    private var latestRevision: [String: UInt64] = [:]

    // MARK: - Reading

    func readText(at url: URL,
                  phase: (@Sendable (VaultAccessPhase) -> Void)? = nil) async throws -> String {
        let data = try await readData(at: url, phase: phase)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VaultAccessError.notUTF8
        }
        return text
    }

    func readData(at url: URL,
                  phase: (@Sendable (VaultAccessPhase) -> Void)? = nil) async throws -> Data {
        try await materializeIfNeeded(url, phase: phase)
        try Task.checkCancellation()
        phase?(.reading)
        return try await coordinatedRead(url)
    }

    // MARK: - Writing

    /// Writes `data` unless a newer revision for the same path has already been stored.
    /// The actor's serialisation makes the revision check and the write atomic with respect
    /// to other saves of the same document.
    func write(_ data: Data, to url: URL, revision: UInt64) async throws {
        let key = url.standardizedFileURL.path
        guard revision >= (latestRevision[key] ?? 0) else { return }
        latestRevision[key] = revision
        try await coordinatedWrite(data, to: url)
    }

    /// Convenience for callers that own the ordering themselves (e.g. a freshly created note).
    func write(_ data: Data, to url: URL) async throws {
        let key = url.standardizedFileURL.path
        latestRevision[key] = (latestRevision[key] ?? 0) &+ 1
        try await coordinatedWrite(data, to: url)
    }

    // MARK: - iCloud

    /// True when the item has a readable local copy (or is not in iCloud at all).
    func hasLocalContents(at url: URL) -> Bool {
        guard let status = downloadStatus(of: url) else { return true }
        return status != .notDownloaded
    }

    /// Requests the download of a single note. Never walks the vault: only the file the user
    /// actually opened (plus an explicit, bounded prefetch) is pulled down.
    func requestDownload(at url: URL) {
        guard let status = downloadStatus(of: url), status != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func downloadStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        let values = try? url.resourceValues(forKeys: Self.iCloudKeys)
        guard values?.isUbiquitousItem == true else { return nil }
        return values?.ubiquitousItemDownloadingStatus
    }

    private static let iCloudKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemIsDownloadingKey,
    ]

    /// Waits (cancellably) until the note has a usable local copy.
    private func materializeIfNeeded(_ url: URL,
                                     phase: (@Sendable (VaultAccessPhase) -> Void)?) async throws {
        let values = try? url.resourceValues(forKeys: Self.iCloudKeys)
        guard values?.isUbiquitousItem == true else { return }

        let status = values?.ubiquitousItemDownloadingStatus
        if status == .current { return }

        // A stale-but-present local copy is readable immediately; refresh it in the
        // background so the next open is current instead of blocking this one.
        if status == .downloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        phase?(.downloading)
        let deadline = Date().addingTimeInterval(Self.downloadTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let current = try? url.resourceValues(forKeys: Self.iCloudKeys)
            if current?.ubiquitousItemDownloadingStatus == .current { return }
            if current?.ubiquitousItemDownloadingStatus == .downloaded {
                // Usable now; the newer revision can arrive later.
                return
            }
            if let error = current?.ubiquitousItemDownloadingError {
                throw VaultAccessError.iCloudDownloadFailed(error.localizedDescription)
            }
            try await Task.sleep(nanoseconds: Self.downloadPollInterval)
        }
        throw VaultAccessError.iCloudDownloadTimedOut
    }

    private static let downloadTimeout: TimeInterval = 30
    private static let downloadPollInterval: UInt64 = 200_000_000   // 0.2s

    // MARK: - Coordinated I/O primitives

    private func coordinatedRead(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Self.coordinationQueue.async {
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var outcome: Result<Data, Error>?
                coordinator.coordinate(readingItemAt: url,
                                       options: [],
                                       error: &coordinationError) { readableURL in
                    outcome = Result { try Data(contentsOf: readableURL, options: .mappedIfSafe) }
                }
                if let coordinationError {
                    continuation.resume(
                        throwing: VaultAccessError.readFailed(coordinationError.localizedDescription))
                    return
                }
                guard let outcome else {
                    continuation.resume(
                        throwing: VaultAccessError.readFailed(url.lastPathComponent))
                    return
                }
                switch outcome {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    // Wrap the Foundation error so the editor always has a non-empty,
                    // user-presentable message to show in its failure state.
                    continuation.resume(
                        throwing: VaultAccessError.readFailed(error.localizedDescription))
                }
            }
        }
    }

    private func coordinatedWrite(_ data: Data, to url: URL) async throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.coordinationQueue.async {
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var writeError: Error?
                let options: NSFileCoordinator.WritingOptions = exists ? .forReplacing : []
                coordinator.coordinate(writingItemAt: url,
                                       options: options,
                                       error: &coordinationError) { writableURL in
                    do {
                        try data.write(to: writableURL, options: .atomic)
                    } catch {
                        writeError = error
                    }
                }
                if let coordinationError {
                    continuation.resume(
                        throwing: VaultAccessError.writeFailed(coordinationError.localizedDescription))
                } else if let writeError {
                    continuation.resume(
                        throwing: VaultAccessError.writeFailed(writeError.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
