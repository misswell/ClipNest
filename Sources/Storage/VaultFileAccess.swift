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
    private static let queueMarker = DispatchSpecificKey<Bool>()
    private static let coordinationQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.clipnest.vault.coordination", qos: .utility)
        queue.setSpecific(key: queueMarker, value: true)
        return queue
    }()

    // Accessed only on coordinationQueue. Pending editor saves follow a moved file rather
    // than recreating its old path. Creation of a new item releases that path for reuse.
    private static var movedPaths: [String: String] = [:]
    private static var editorRevisions: [String: UInt64] = [:]

    nonisolated static func performMutation<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueMarker) == true { return try operation() }
        return try coordinationQueue.sync(execute: operation)
    }

    /// Small local metadata files (trash manifest) need synchronous access from CRUD callers.
    nonisolated static func readDataImmediately(at url: URL) throws -> Data {
        try performMutation {
            var coordinationError: NSError?
            var outcome: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                outcome = Result { try Data(contentsOf: readable) }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CocoaError(.fileReadUnknown) }
            return try outcome.get()
        }
    }

    nonisolated static func writeDataImmediately(_ data: Data, to url: URL) throws {
        try performMutation {
            var coordinationError: NSError?
            var outcome: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writable in
                outcome = Result { try data.write(to: writable, options: .atomic) }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CocoaError(.fileWriteUnknown) }
            try outcome.get()
        }
    }

    nonisolated static func moveItem(at source: URL, to destination: URL, followPendingWrites: Bool = true) throws {
        try performMutation {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var outcome: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: source, options: .forMoving,
                                   writingItemAt: destination, options: [],
                                   error: &coordinationError) { from, to in
                outcome = Result { try FileManager.default.moveItem(at: from, to: to) }
                if case .success = outcome { coordinator.item(at: from, didMoveTo: to) }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CocoaError(.fileWriteUnknown) }
            try outcome.get()
            guard followPendingWrites else { return }
            let old = source.standardizedFileURL.path
            let new = destination.standardizedFileURL.path
            for (key, value) in movedPaths {
                if value == old || value.hasPrefix(old + "/") {
                    movedPaths[key] = new + value.dropFirst(old.count)
                }
            }
            movedPaths.removeValue(forKey: new)
            movedPaths[old] = new
            for (key, value) in editorRevisions where key == old || key.hasPrefix(old + "/") {
                let target = new + key.dropFirst(old.count)
                editorRevisions[target] = max(editorRevisions[target] ?? 0, value)
                editorRevisions.removeValue(forKey: key)
            }
        }
    }

    nonisolated static func createText(_ text: String, at url: URL) throws {
        try performMutation {
            var coordinationError: NSError?
            var outcome: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [],
                                           error: &coordinationError) { target in
                outcome = Result {
                    try Data(text.utf8).write(to: target, options: .withoutOverwriting)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CocoaError(.fileWriteUnknown) }
            try outcome.get()
            movedPaths.removeValue(forKey: url.standardizedFileURL.path)
            editorRevisions.removeValue(forKey: url.standardizedFileURL.path)
        }
    }

    /// Queue the save before returning to the caller, so a following move/delete waits
    /// for it even if the MainActor callback has not run yet.
    nonisolated static func enqueueExistingText(_ text: String, to url: URL, revision: UInt64,
                                                historyRoot: URL? = nil,
                                                completion: @escaping @Sendable (Result<URL?, Error>) -> Void) {
        coordinationQueue.async {
            do {
                var targetPath = url.standardizedFileURL.path
                var visited = Set<String>()
                while visited.insert(targetPath).inserted,
                      let source = Self.movedPaths.keys
                        .filter({ targetPath == $0 || targetPath.hasPrefix($0 + "/") })
                        .max(by: { $0.count < $1.count }),
                      let destination = Self.movedPaths[source] {
                    targetPath = destination + targetPath.dropFirst(source.count)
                }
                let target = URL(fileURLWithPath: targetPath)
                guard FileManager.default.fileExists(atPath: targetPath),
                      revision >= (Self.editorRevisions[targetPath] ?? 0) else {
                    completion(.success(nil))
                    return
                }
                var coordinationError: NSError?
                var outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing,
                                               error: &coordinationError) { writable in
                    outcome = Result {
                        // Recheck inside the accessor: another app may have deleted it.
                        guard FileManager.default.fileExists(atPath: writable.path) else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        if let historyRoot,
                           let previous = String(data: try Data(contentsOf: writable), encoding: .utf8), previous != text {
                            try VaultHistory.record(previous, for: writable, root: historyRoot)
                        }
                        try Data(text.utf8).write(to: writable, options: .atomic)
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let outcome else { throw CocoaError(.fileWriteUnknown) }
                try outcome.get()
                Self.editorRevisions[targetPath] = revision
                completion(.success(target))
            } catch {
                completion(.failure(VaultAccessError.writeFailed(error.localizedDescription)))
            }
        }
    }

    /// Autosaves only update an existing document. A delete must never resurrect it.
    func writeExistingText(_ text: String, to url: URL, revision: UInt64) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            Self.enqueueExistingText(text, to: url, revision: revision) { result in
                continuation.resume(with: result)
            }
        }
    }

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

    /// Legacy iCloud Drive placeholders are named `.photo.jpg.icloud`. Keep using the
    /// logical `photo.jpg` URL for resource queries, downloading and coordinated reads.
    nonisolated static func logicalURL(for url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
    }

    nonisolated private static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// Resolution must not require downloaded bytes: otherwise a phone-created attachment
    /// is rejected before `readData` can request its iCloud download on the Mac.
    nonisolated static func isAvailableForReading(at url: URL) -> Bool {
        let logical = logicalURL(for: url).standardizedFileURL
        let manager = FileManager.default
        return manager.fileExists(atPath: logical.path)
            || manager.fileExists(atPath: placeholderURL(for: logical).path)
            || manager.isUbiquitousItem(at: logical)
    }

    private func cloudResourceValues(at url: URL) -> URLResourceValues? {
        // Construct fresh URLs on every poll; URL resource values can cache the previous
        // download status while the item is being materialised.
        let logical = URL(fileURLWithPath: Self.logicalURL(for: url).path)
        let values = try? logical.resourceValues(forKeys: Self.iCloudKeys)
        if values?.isUbiquitousItem == true { return values }
        return (try? Self.placeholderURL(for: logical).resourceValues(forKeys: Self.iCloudKeys)) ?? values
    }

    /// AVPlayer reads a private local copy, while the original iCloud/scoped file is read
    /// only inside a coordinated accessor. The caller owns and removes this temporary file.
    func mediaPreviewCopy(at url: URL) async throws -> URL {
        try await materializeIfNeeded(url, phase: nil)
        return try await withCheckedThrowingContinuation { continuation in
            Self.coordinationQueue.async {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClipNest-Media-" + UUID().uuidString).appendingPathExtension(url.pathExtension)
                var coordinationError: NSError?
                var outcome: Result<URL, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    outcome = Result { try FileManager.default.copyItem(at: readable, to: destination); return destination }
                }
                if let coordinationError { continuation.resume(throwing: coordinationError) }
                else if let outcome { continuation.resume(with: outcome) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
    }

    nonisolated static func importMedia(from source: URL, root: URL) throws -> URL {
        try performMutation {
            let directory = root.appendingPathComponent("Attachments", isDirectory: true)
            guard VaultNoteCatalog.isInside(directory, root: root) else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("Recording-" + UUID().uuidString).appendingPathExtension("m4a")
            var coordinationError: NSError?
            var outcome: Result<URL, Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: [],
                                           error: &coordinationError) { readable, writable in
                outcome = Result { try FileManager.default.copyItem(at: readable, to: writable); return destination }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CocoaError(.fileWriteUnknown) }
            return try outcome.get()
        }
    }

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
        let values = cloudResourceValues(at: url)
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
        let values = cloudResourceValues(at: url)
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
            let current = cloudResourceValues(at: url)
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
