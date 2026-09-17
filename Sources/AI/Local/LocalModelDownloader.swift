import CryptoKit
import Foundation

/// The published description of the downloadable model (China plan §4).
///
/// `files` is what makes a real resumable download possible: each entry has its own size and
/// digest, so a partially transferred file can be resumed and verified on its own. A manifest
/// with an empty `files` array is still accepted — the single-file case is then driven by the
/// top-level `size` / `sha256`.
struct LocalModelManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var name: String
        var size: Int64
        var sha256: String
    }

    var id: String
    var version: Int
    var size: Int64
    var sha256: String
    var files: [File]

    enum CodingKeys: String, CodingKey {
        case id, version, size, sha256, files
    }

    init(id: String, version: Int, size: Int64, sha256: String, files: [File]) {
        self.id = id
        self.version = version
        self.size = size
        self.sha256 = sha256
        self.files = files
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
    }

    /// Files to transfer, with a single-file fallback for manifests that list none.
    var transferableFiles: [File] {
        if !files.isEmpty { return files }
        guard !sha256.isEmpty else { return [] }
        return [File(name: "model.safetensors", size: size, sha256: sha256)]
    }

    var totalBytes: Int64 {
        let sum = transferableFiles.reduce(Int64(0)) { $0 + $1.size }
        return sum > 0 ? sum : size
    }

    /// Rejects a manifest that describes a different model or nothing at all, before a
    /// single byte is transferred.
    func validate(expectedIdentifier: String) throws {
        guard id == expectedIdentifier else {
            throw LocalModelDownloadError.manifestMismatch(
                expected: expectedIdentifier, found: id)
        }
        let files = transferableFiles
        guard !files.isEmpty else {
            throw LocalModelDownloadError.invalidManifest(
                String(localized: "The manifest lists no files."))
        }
        for file in files {
            guard !file.name.isEmpty, !file.name.contains("/"), !file.name.contains("..") else {
                throw LocalModelDownloadError.invalidManifest(
                    String(localized: "Unsafe file name in manifest: \(file.name)"))
            }
            guard file.size > 0, !file.sha256.isEmpty else {
                throw LocalModelDownloadError.invalidManifest(
                    String(localized: "File entry is missing its size or digest: \(file.name)"))
            }
        }
    }
}

enum LocalModelDownloadError: LocalizedError, Equatable {
    case notConfigured
    case invalidManifest(String)
    case manifestMismatch(expected: String, found: String)
    case badStatus(Int)
    case shortResponse(expected: Int64, received: Int64)
    case checksumMismatch(file: String)
    case ioFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "No model download server is configured.")
        case let .invalidManifest(reason):
            return String(localized: "The model manifest is invalid: \(reason)")
        case let .manifestMismatch(expected, found):
            return String(localized: "The server offered “\(found)” but “\(expected)” was expected.")
        case let .badStatus(code):
            return String(localized: "The download server returned HTTP \(code).")
        case let .shortResponse(expected, received):
            return String(localized: "The download stopped early (\(received) of \(expected) bytes).")
        case let .checksumMismatch(file):
            return String(localized: "The downloaded file failed verification: \(file)")
        case let .ioFailure(reason):
            return String(localized: "Could not write the model to disk: \(reason)")
        case .cancelled:
            return String(localized: "The download was cancelled.")
        }
    }
}

/// The network seam. Only this protocol touches URLSession, so every resume / verify /
/// atomic-rename rule below is exercised by tests without a server.
protocol ModelDownloadTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport: plain buffered requests. The downloader asks for bounded byte
/// ranges, so this never holds more than one chunk in memory and a dropped connection is
/// recoverable — the next chunk simply re-requests from where the file left off.
struct URLSessionModelDownloadTransport: ModelDownloadTransport {
    var session: URLSession = .shared

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelDownloadError.ioFailure(
                String(localized: "The server sent a non-HTTP response."))
        }
        return (data, http)
    }
}

/// Progress events from a model download (China plan §4: progress, retry, cancel).
enum LocalModelDownloadEvent: Equatable, Sendable {
    case progress(fraction: Double, bytesWritten: Int64, totalBytes: Int64)
    case verifying
    case finished
}

/// Resumable, verifying model downloader (China plan §4).
///
/// The rules this enforces, all of them testable without a network:
///
/// - Nothing is used until it has been verified: files land in a staging directory and are
///   only promoted by an atomic directory rename.
/// - A transfer is resumable: partially written files are kept as `.part` and re-requested
///   with a `Range` header.
/// - Every file is checked against the manifest digest before promotion.
/// - Cancellation keeps the partial files, so a cancel is never a restart from zero.
struct LocalModelDownloader: Sendable {
    /// 4 MB per request: small enough that a retry is cheap, large enough that a 350 MB
    /// model is ~90 requests rather than thousands.
    static let chunkSize: Int64 = 4 * 1024 * 1024
    /// Transient failures are retried with a short backoff before giving up.
    static let maximumAttemptsPerChunk = 4

    var store: LocalModelStore
    var transport: any ModelDownloadTransport
    var chunkSize: Int64 = LocalModelDownloader.chunkSize
    var maximumAttemptsPerChunk: Int = LocalModelDownloader.maximumAttemptsPerChunk
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }

    /// Fetches and validates the manifest. Sent by the CDN, never by Hugging Face (§4).
    func fetchManifest(from url: URL) async throws -> LocalModelManifest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LocalModelDownloadError.badStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(LocalModelManifest.self, from: data)
        } catch {
            throw LocalModelDownloadError.invalidManifest(error.localizedDescription)
        }
    }

    /// Downloads every file, verifies it, then promotes staging to the live directory.
    func download(_ manifest: LocalModelManifest,
                  baseURL: URL,
                  identifier: String) -> AsyncThrowingStream<LocalModelDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try manifest.validate(expectedIdentifier: identifier)
                    try store.prepareStaging()
                    let total = manifest.transferableFiles.reduce(Int64(0)) { $0 + $1.size }
                    var completed = Int64(0)

                    for file in manifest.transferableFiles {
                        try Task.checkCancellation()
                        let written = try await transfer(file: file,
                                                         baseURL: baseURL,
                                                         alreadyCompleted: completed,
                                                         total: total,
                                                         emit: { event in
                                                             continuation.yield(event)
                                                         })
                        completed += written
                    }

                    continuation.yield(.verifying)
                    try Task.checkCancellation()
                    try verify(manifest)

                    // Written last so a crash mid-promotion can never look like a valid install.
                    try store.writeInstalledManifest(manifest)
                    try store.promoteStaging(version: manifest.version)

                    continuation.yield(.finished)
                    continuation.finish()
                } catch is CancellationError {
                    // Partial `.part` files stay on disk: resuming is the whole point.
                    continuation.finish(throwing: LocalModelDownloadError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    // MARK: - One file

    private func transfer(file: LocalModelManifest.File,
                          baseURL: URL,
                          alreadyCompleted: Int64,
                          total: Int64,
                          emit: @Sendable (LocalModelDownloadEvent) -> Void) async throws -> Int64 {
        let destination = store.stagingFileURL(named: file.name)
        var written = Self.existingSize(of: destination)

        if written > file.size {
            // A stale, longer file from an older manifest: start this file over.
            try? FileManager.default.removeItem(at: destination)
            written = 0
        }

        while written < file.size {
            try Task.checkCancellation()
            let upper = min(written + chunkSize, file.size) - 1
            var request = URLRequest(url: baseURL.appendingPathComponent(file.name))
            request.timeoutInterval = 60
            request.setValue("bytes=\(written)-\(upper)", forHTTPHeaderField: "Range")

            let (data, response) = try await requestChunk(request)
            switch response.statusCode {
            case 206:
                // Correct resume: append exactly what was asked for.
                break
            case 200:
                // The server ignored the range and sent the whole file. Only usable when we
                // have not written anything yet; otherwise restart this file cleanly.
                if written > 0 {
                    try? FileManager.default.removeItem(at: destination)
                    written = 0
                }
                if Int64(data.count) < file.size { continue }
            default:
                throw LocalModelDownloadError.badStatus(response.statusCode)
            }

            let remaining = file.size - written
            guard Int64(data.count) <= remaining else {
                throw LocalModelDownloadError.ioFailure(
                    String(localized: "The server sent more data than requested."))
            }
            try append(data, to: destination)
            written += Int64(data.count)
            emit(.progress(fraction: total > 0
                                ? Double(alreadyCompleted + written) / Double(total)
                                : 0,
                           bytesWritten: alreadyCompleted + written,
                           totalBytes: total))
        }
        return written
    }

    /// Retries transient transport failures with a linear backoff. A 4xx/5xx status is not
    /// retried here — the caller's status handling decides.
    private func requestChunk(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                return try await transport.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= maximumAttemptsPerChunk { throw error }
                try await sleep(TimeInterval(attempt))
            }
        }
    }

    // MARK: - Verification

    private func verify(_ manifest: LocalModelManifest) throws {
        for file in manifest.transferableFiles {
            let url = store.stagingFileURL(named: file.name)
            let size = Self.existingSize(of: url)
            guard size == file.size else {
                throw LocalModelDownloadError.shortResponse(expected: file.size, received: size)
            }
            guard try Self.sha256(of: url) == file.sha256.lowercased() else {
                throw LocalModelDownloadError.checksumMismatch(file: file.name)
            }
        }
    }

    /// Streams the file through SHA-256 so a 335 MB weight file never enters memory.
    static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LocalModelDownloadError.ioFailure(
                String(localized: "Cannot read \(url.lastPathComponent)."))
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Small filesystem helpers

    static func existingSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func append(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw LocalModelDownloadError.ioFailure(error.localizedDescription)
            }
        }
    }
}
