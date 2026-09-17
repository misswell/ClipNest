import Foundation

/// Identity of the one downloadable local model (China plan §2, §3).
///
/// Qwen3-0.6B at 4-bit is the deliberate choice: Apache-2.0, ~335 MB of weights, no vision
/// tower. 1.7B is already near 1 GB and Qwen3.5-0.8B ships a multimodal architecture that
/// ClipNest would never use, because photos go through Vision OCR first (§23).
struct LocalModelDescriptor: Equatable, Sendable {
    var identifier: String = "qwen3-0.6b-4bit"
    var displayName: String = "Qwen3 0.6B"
    var detail: String = String(localized: "Chinese-optimized · 4-bit")
    /// Advertised size, used only before a manifest has been fetched (§3: "约 350 MB").
    var approximateBytes: Int64 = 351_000_000
    var version: Int = 1

    static let qwen3 = LocalModelDescriptor()
}

/// Pure filesystem view of the installed model. No UI, no actor: the router needs a cheap
/// readiness check from whatever context it is on.
struct LocalModelStore: Sendable {
    var root: URL
    var descriptor: LocalModelDescriptor

    /// `Application Support/ClipNest/Models` — never Documents, never the vault, never iCloud
    /// (China plan §3: the model is an application cache resource).
    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true))
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("ClipNest", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    init(root: URL = LocalModelStore.defaultRoot(),
         descriptor: LocalModelDescriptor = .qwen3) {
        self.root = root
        self.descriptor = descriptor
    }

    var modelDirectory: URL { root.appendingPathComponent(descriptor.identifier, isDirectory: true) }
    var stagingDirectory: URL {
        root.appendingPathComponent(".staging-\(descriptor.identifier)", isDirectory: true)
    }
    var replacementDirectory: URL {
        root.appendingPathComponent(".replaced-\(descriptor.identifier)", isDirectory: true)
    }

    func stagingFileURL(named name: String) -> URL {
        stagingDirectory.appendingPathComponent(name)
    }

    var installedManifestURL: URL {
        modelDirectory.appendingPathComponent("model-manifest.json")
    }

    /// True when this hardware can run MLX at all. MLX needs Apple silicon's unified memory;
    /// Intel Macs get Local Lite plus Online instead (China plan §27).
    static var isHardwareCapable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Reads the manifest that was written next to the weights at install time. This file —
    /// not UserDefaults — is the authority on what is actually on disk.
    func installedManifest() -> LocalModelManifest? {
        guard let data = try? Data(contentsOf: installedManifestURL) else { return nil }
        return try? JSONDecoder().decode(LocalModelManifest.self, from: data)
    }

    /// Cheap readiness check: the recorded files must all be present at their recorded sizes.
    /// Digests were verified when the model was installed; re-hashing 350 MB on every launch
    /// would cost more than it protects against.
    func isInstalled() -> Bool {
        guard let manifest = installedManifest() else { return false }
        guard manifest.id == descriptor.identifier else { return false }
        let files = manifest.transferableFiles
        guard !files.isEmpty else { return false }
        for file in files {
            let url = modelDirectory.appendingPathComponent(file.name)
            let size = LocalModelDownloader.existingSize(of: url)
            guard size == file.size else { return false }
        }
        return true
    }

    func installedBytes() -> Int64 {
        guard let manifest = installedManifest() else { return 0 }
        return manifest.transferableFiles.reduce(Int64(0)) { total, file in
            total + LocalModelDownloader.existingSize(
                of: modelDirectory.appendingPathComponent(file.name))
        }
    }

    // MARK: - Installation lifecycle

    func prepareStaging() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            // A 350 MB re-downloadable cache must not inflate the user's backup.
            var mutableRoot = root
            var rootValues = URLResourceValues()
            rootValues.isExcludedFromBackup = true
            try? mutableRoot.setResourceValues(rootValues)
            try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw LocalModelDownloadError.ioFailure(error.localizedDescription)
        }
    }

    func writeInstalledManifest(_ manifest: LocalModelManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        do {
            try data.write(to: stagingDirectory.appendingPathComponent("model-manifest.json"))
        } catch {
            throw LocalModelDownloadError.ioFailure(error.localizedDescription)
        }
    }

    /// Promotes verified staging into place with a single directory rename (§4: 原子 rename).
    func promoteStaging(version: Int) throws {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: replacementDirectory.path) {
                try manager.removeItem(at: replacementDirectory)
            }
            if manager.fileExists(atPath: modelDirectory.path) {
                try manager.moveItem(at: modelDirectory, to: replacementDirectory)
            }
            try manager.moveItem(at: stagingDirectory, to: modelDirectory)
            try? manager.removeItem(at: replacementDirectory)
            var mutableDirectory = modelDirectory
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            try? mutableDirectory.setResourceValues(directoryValues)
        } catch {
            throw LocalModelDownloadError.ioFailure(error.localizedDescription)
        }
    }

    /// Removes both the installed model and any partial download left by a cancel.
    func deleteInstalled() throws {
        let manager = FileManager.default
        for url in [modelDirectory, stagingDirectory, replacementDirectory] {
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try manager.removeItem(at: url)
            } catch {
                throw LocalModelDownloadError.ioFailure(error.localizedDescription)
            }
        }
    }
}

/// What the Settings screen shows (China plan §28, §30).
enum LocalModelState: Equatable {
    /// This device cannot run the model (Intel Mac) — not an error the user can fix.
    case unsupportedDevice(String)
    /// Apple silicon, but nothing downloaded yet. This is the normal resting state.
    case notInstalled
    case downloading(fraction: Double)
    case installed(version: Int, bytes: Int64)
    case failed(String)

    var isReady: Bool {
        if case .installed = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Owns the installed-model state and the download lifecycle (China plan §3, §4, §32).
///
/// Everything it publishes is derived from the filesystem, so a model deleted in Finder, a
/// half-finished download, or a cancelled transfer are all reported correctly on next launch.
@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()

    @Published private(set) var state: LocalModelState = .notInstalled
    @Published private(set) var lastError: String?

    let store: LocalModelStore
    /// The CDN that serves the manifest (§4). Empty means "not configured" and the UI says so
    /// rather than pretending a download is possible.
    var manifestURL: URL?

    private var downloadTask: Task<Void, Never>?
    private var lastProgressUpdate = Date.distantPast

    init(store: LocalModelStore = LocalModelStore(),
         manifestURL: URL? = LocalModelManager.configuredManifestURL()) {
        self.store = store
        self.manifestURL = manifestURL
        refresh()
    }

    /// The manifest location, from Settings. Runtime downloads never use Hugging Face (§4).
    /// A deployment points this at its own Tencent COS / Aliyun OSS bucket.
    ///
    /// `nonisolated` because it only reads UserDefaults, and Settings needs it as a default
    /// argument outside the main actor.
    nonisolated static func configuredManifestURL() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: ClipNestSettings.localModelManifestURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme != nil
        else { return nil }
        return url
    }

    var descriptor: LocalModelDescriptor { store.descriptor }

    /// Whether a download could be started at all. Settings uses this so it never offers a
    /// button that can only fail, and so the failure is explained before the click.
    nonisolated static var isDownloadConfigured: Bool { configuredManifestURL() != nil }

    /// Recomputes the published state from disk.
    func refresh() {
        guard LocalModelStore.isHardwareCapable else {
            state = .unsupportedDevice(
                String(localized: "This Mac cannot run the on-device model. Local Lite and Online AI are still available."))
            return
        }
        if store.isInstalled(), let manifest = store.installedManifest() {
            state = .installed(version: manifest.version, bytes: store.installedBytes())
        } else if case .downloading = state {
            // Keep the live progress; a refresh during a download must not reset the bar.
        } else if case .failed = state {
            // Keep the failure visible until the user acts.
        } else {
            state = .notInstalled
        }
    }

    // MARK: - Download

    func download() async {
        guard !state.isBusy else { return }
        guard LocalModelStore.isHardwareCapable else {
            refresh()
            return
        }
        guard let manifestURL else {
            state = .failed(LocalModelDownloadError.notConfigured.errorDescription
                ?? String(localized: "No model download server is configured."))
            return
        }

        lastError = nil
        state = .downloading(fraction: 0)
        let task = Task { [store, descriptor] in
            let downloader = LocalModelDownloader(store: store,
                                                  transport: URLSessionModelDownloadTransport())
            do {
                let manifest = try await downloader.fetchManifest(from: manifestURL)
                let baseURL = manifestURL.deletingLastPathComponent()
                for try await event in downloader.download(manifest,
                                                           baseURL: baseURL,
                                                           identifier: descriptor.identifier) {
                    switch event {
                    case let .progress(fraction, _, _):
                        publishProgress(fraction)
                    case .verifying, .finished:
                        break
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state = .failed(Self.message(for: error))
                }
            }
        }
        downloadTask = task
        await task.value
        downloadTask = nil
        // The disk is the authority; whatever happened, report what is actually installed.
        state = .notInstalled
        refresh()
    }

    /// Cancelling keeps the `.part` files, so the next attempt resumes instead of restarting.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func publishProgress(_ fraction: Double) {
        // Coalesce updates: the downloader emits one per 4 MB chunk, which is already coarse,
        // but a fast link can produce many in a single frame.
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate) > 0.1 || fraction >= 1 else { return }
        lastProgressUpdate = now
        state = .downloading(fraction: fraction)
    }

    // MARK: - Delete

    func deleteModel() {
        cancelDownload()
        do {
            try store.deleteInstalled()
            UserDefaults.standard.removeObject(forKey: ClipNestSettings.localModelInstalledVersion)
            UserDefaults.standard.removeObject(forKey: ClipNestSettings.localModelLastUsedAt)
            lastError = nil
            refresh()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    // MARK: - Runtime hand-off

    /// The installed store when the model can actually be loaded, otherwise `nil`.
    ///
    /// Anything that wants the *model* rather than a note provider (search keyword expansion,
    /// for instance) goes through here, so "is it really usable" is answered in one place.
    func readyStore() -> LocalModelStore? {
        state.isReady ? store : nil
    }

    /// The provider to use for this capture, or `nil` when no model is installed.
    ///
    /// Returning `nil` is the normal case for a fresh install and means the router falls back
    /// to Local Lite — it is never a reason to touch the network (§9, §11).
    func makeProviderIfReady(profiles: [CategoryProfile]) -> (any NoteGenerating)? {
        guard state.isReady else { return nil }
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: ClipNestSettings.localModelLastUsedAt)
        UserDefaults.standard.set(store.installedManifest()?.version ?? descriptor.version,
                                  forKey: ClipNestSettings.localModelInstalledVersion)
        return LocalModelRuntime.shared.provider(modelDirectory: store.modelDirectory,
                                                profiles: profiles)
    }

    /// Warms the weights while the user is still on their way to a capture.
    ///
    /// Safe to call as often as the UI likes: it is a no-op when the engine is already resident,
    /// and it never throws — a preload that fails must not surface an error, because the capture
    /// path is the place that knows how to report one (§22).
    func preloadIfReady() {
        guard state.isReady else { return }
        let directory = store.modelDirectory
        Task.detached(priority: .utility) {
            await LocalModelRuntime.shared.preload(directory: directory)
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
