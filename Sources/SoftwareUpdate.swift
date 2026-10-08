#if os(macOS)
import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let saveBeforeSoftwareUpdate = Notification.Name("saveBeforeSoftwareUpdate")
}

@MainActor
final class SoftwareUpdate: ObservableObject {
    static let shared = SoftwareUpdate()
    enum State: Equatable { case idle, checking, current, available, downloading, preparing, installing, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var release: ClipNestUpdateRelease?
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    @Published var showUpdate = false
    let currentVersion: String
    private let session: URLSession
    private let defaults: UserDefaults
    private var operation: Task<Void, Never>?
    private var started = false
    var isBusy: Bool { [.checking, .downloading, .preparing, .installing].contains(state) }
    var blocksEditing: Bool { state == .installing }
    static var failureMarker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipNest/update-failure.txt")
    }

    init(session: URLSession = .shared, defaults: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.session = session
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    func start() {
        guard !started, NSClassFromString("XCTestCase") == nil else { return }
        started = true
        if let data = try? Data(contentsOf: Self.failureMarker) {
            let value = String(decoding: data, as: UTF8.self)
            errorMessage = value.hasPrefix("backup:")
                ? String(localized: "The update could not be completed. Your previous application is saved at \(String(value.dropFirst(7))).")
                : String(localized: "The update could not be completed. Your previous application was kept. Please try again.")
            state = .failed
            showUpdate = true
            try? FileManager.default.removeItem(at: Self.failureMarker)
            return
        }
        let automatic = defaults.object(forKey: "automaticallyCheckForUpdates") as? Bool ?? true
        let last = defaults.object(forKey: "lastSuccessfulUpdateCheck") as? Date ?? .distantPast
        if automatic && Date().timeIntervalSince(last) >= 24 * 60 * 60 { check(manual: false) }
    }

    func check(manual: Bool = true) {
        guard !isBusy else { if manual { showUpdate = true }; return }
        if manual { showUpdate = true }
        state = .checking
        errorMessage = nil
        release = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: ClipNestUpdateIdentity.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("ClipNest/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw ClipNestUpdateError.invalidRelease }
                // A repository without a published release has nothing to install.
                if response.statusCode == 404 {
                    defaults.set(Date(), forKey: "lastSuccessfulUpdateCheck")
                    state = .current
                    operation = nil
                    return
                }
                guard response.statusCode == 200 else { throw ClipNestUpdateError.network(response.statusCode) }
                let candidate = try ClipNestUpdateRelease.decode(data)
                defaults.set(Date(), forKey: "lastSuccessfulUpdateCheck")
                if candidate.isNewer(than: currentVersion) {
                    release = candidate
                    state = .available
                    showUpdate = true
                } else { state = .current }
            } catch {
                if Task.isCancelled { state = .idle }
                else { fail(error) }
            }
            operation = nil
        }
    }

    func cancel() {
        guard state != .installing else { return }
        operation?.cancel()
    }

    func downloadAndInstall(store: VaultStore) {
        guard !isBusy, let release else { return }
        state = .downloading
        progress = 0
        errorMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ClipNest-update-\(UUID().uuidString)", isDirectory: true)
            var handedToInstaller = false
            defer {
                if !handedToInstaller { try? FileManager.default.removeItem(at: workspace) }
                operation = nil
            }
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let archive = workspace.appendingPathComponent("update.zip")
                let downloader = UpdateDownload(destination: archive, maximumSize: release.size) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                try await downloader.download(release.archiveURL)
                try Task.checkCancellation()
                state = .preparing
                let package = workspace.appendingPathComponent("package", isDirectory: true)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let validation = Task.detached(priority: .userInitiated) {
                    try ClipNestUpdatePackage.unpack(archive, release: release, into: package)
                }
                let source = try await withTaskCancellationHandler {
                    try await validation.value
                } onCancel: { validation.cancel() }
                try Task.checkCancellation()
                let destination = Bundle.main.bundleURL.standardizedFileURL
                guard !destination.path.contains("/AppTranslocation/"),
                      destination.resolvingSymlinksInPath() == destination,
                      FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path),
                      FileManager.default.isWritableFile(atPath: destination.path) else { throw ClipNestUpdateError.cannotInstall }
                try ClipNestUpdatePackage.verifySignature(destination)
                let originalHelper = ClipNestUpdateIdentity.helper(in: destination)
                guard FileManager.default.isExecutableFile(atPath: originalHelper.path) else { throw ClipNestUpdateError.helperMissing }
                let installerDirectory = workspace.appendingPathComponent("installer", isDirectory: true)
                try FileManager.default.createDirectory(at: installerDirectory, withIntermediateDirectories: true)
                let helper = installerDirectory.appendingPathComponent(ClipNestUpdateIdentity.helperName)
                try FileManager.default.copyItem(at: originalHelper, to: helper)
                state = .installing
                // Give disabled native controls a run-loop turn before flushing editors.
                await Task.yield()
                NotificationCenter.default.post(name: .saveBeforeSoftwareUpdate, object: nil)
                try await store.waitForEditorSaves()
                let installer = Process()
                installer.executableURL = helper
                installer.arguments = [String(ProcessInfo.processInfo.processIdentifier), source.path, destination.path,
                                       release.version, workspace.path, Self.failureMarker.path]
                installer.standardOutput = FileHandle.nullDevice
                installer.standardError = FileHandle.nullDevice
                try installer.run()
                handedToInstaller = true
                NSApplication.shared.terminate(nil)
            } catch {
                if Task.isCancelled { state = .available }
                else { fail(error) }
            }
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .failed
    }
}

/// URLSession owns its delegate until invalidation. The destination is moved during
/// didFinishDownloadingTo because URLSession removes the temporary file afterwards.
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let maximumSize: Int64
    let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var failure: Error?
    private let lock = NSLock()
    private var cancelled = false
    init(destination: URL, maximumSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination; self.maximumSize = maximumSize; self.progress = progress
    }
    func download(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 30 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let session = self.session
            self.lock.unlock()
            session?.invalidateAndCancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize {
            failure = ClipNestUpdateError.checksum
            downloadTask.cancel()
        } else { progress(min(1, Double(totalBytesWritten) / Double(maximumSize))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw ClipNestUpdateError.invalidRelease }
            guard response.statusCode == 200 else { throw ClipNestUpdateError.network(response.statusCode) }
            guard try location.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(maximumSize) else { throw ClipNestUpdateError.checksum }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
        session.finishTasksAndInvalidate()
        lock.lock(); self.session = nil; lock.unlock()
    }
}
#endif
