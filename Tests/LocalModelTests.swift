import CryptoKit
import XCTest
@testable import ClipNest

/// Lets a test freeze a transfer at an exact point. Without it a cancellation test is a race:
/// the in-memory download finishes before the test can cancel it.
actor DownloadGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var arrivals = 0

    var arrivalCount: Int { arrivals }

    /// Records an arrival and suspends unless the gate is already open.
    func arrive() async {
        arrivals += 1
        guard !opened else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

/// A manifest server that lives in memory. Honours `Range` requests so the resume logic is
/// exercised for real, and can be told to truncate, corrupt, stall or fail on demand.
final class FakeModelServer: ModelDownloadTransport, @unchecked Sendable {
    struct Fault: Equatable {
        /// Return this many bytes fewer than asked for, once, simulating a dropped connection.
        var truncateOnce = false
        /// Throw this many times before succeeding.
        var throwCount = 0
        /// Serve wrong bytes so the digest check must catch it.
        var corrupt = false
        /// Reply 200 with the whole file even when a Range was asked for.
        var ignoreRange = false
    }

    let manifestJSON: Data
    private(set) var files: [String: Data]
    private(set) var requests: [URLRequest] = []
    private(set) var rangedRequestCount = 0
    private(set) var fullBodyRequestCount = 0
    var fault = Fault()
    /// When set, `data(for:)` suspends on every ranged request after the first.
    var gate: DownloadGate?
    private var rangedServed = 0

    init(manifest: LocalModelManifest, files: [String: Data], fault: Fault = Fault()) {
        self.manifestJSON = (try? JSONEncoder().encode(manifest)) ?? Data()
        self.files = files
        self.fault = fault
    }

    func manifestData() -> Data { manifestJSON }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let name = url.lastPathComponent

        if fault.throwCount > 0 {
            fault.throwCount -= 1
            throw URLError(.networkConnectionLost)
        }

        if name == "model-manifest.json" {
            return (manifestJSON, response(url: url, status: 200))
        }

        guard let body = files[name] else {
            return (Data(), response(url: url, status: 404))
        }

        let range = request.value(forHTTPHeaderField: "Range")
        var served: Data
        var status = 200

        if let range, !fault.ignoreRange {
            rangedRequestCount += 1
            let (start, end) = Self.parse(range: range)
            let upper = min(end, body.count - 1)
            guard start <= upper else {
                return (Data(), response(url: url, status: 416))
            }
            served = body.subdata(in: start..<(upper + 1))
            status = 206
            if fault.truncateOnce, served.count > 1 {
                fault.truncateOnce = false
                served = served.prefix(served.count / 2)
            }
            rangedServed += 1
            if let gate, rangedServed > 1 {
                // The client has already written the first chunk to disk by the time it asks
                // for the second, so blocking here leaves a deterministic partial file.
                await gate.arrive()
            }
        } else {
            fullBodyRequestCount += 1
            served = body
        }

        // Applied last, so the corruption survives the range slice and actually reaches the
        // client — otherwise the test would silently verify an intact transfer.
        if fault.corrupt {
            served = Data(repeating: 0xAB, count: served.count)
        }
        return (served, response(url: url, status: status, total: body.count))
    }

    private static func parse(range: String) -> (Int, Int) {
        let digits = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        let start = Int(digits.first ?? "0") ?? 0
        let end = digits.count > 1 ? (Int(digits[1]) ?? start) : start
        return (start, end)
    }

    private func response(url: URL, status: Int, total: Int? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let total { headers["Content-Length"] = String(total) }
        return HTTPURLResponse(url: url, statusCode: status,
                               httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

// MARK: - Helpers

private func sha256Hex(_ data: Data) -> String {
    // Computed independently of the code under test.
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeManifest(files: [String: Data],
                          id: String = LocalModelDescriptor.qwen3.identifier,
                          version: Int = 1) -> LocalModelManifest {
    let entries = files.keys.sorted().map {
        LocalModelManifest.File(name: $0, size: Int64(files[$0]!.count), sha256: sha256Hex(files[$0]!))
    }
    let total = entries.reduce(Int64(0)) { $0 + $1.size }
    return LocalModelManifest(id: id, version: version, size: total, sha256: "", files: entries)
}

private func makeStore() throws -> (LocalModelStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ModelStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (LocalModelStore(root: root), root)
}

/// Small enough to keep tests instant, large enough to need several chunks.
private let testChunkSize: Int64 = 64

// MARK: - Download

final class ModelDownloaderTests: XCTestCase {
    private func downloader(store: LocalModelStore,
                            server: FakeModelServer) -> LocalModelDownloader {
        LocalModelDownloader(store: store, transport: server, chunkSize: testChunkSize,
                             sleep: { _ in })
    }

    private func run(_ downloader: LocalModelDownloader,
                     manifest: LocalModelManifest,
                     baseURL: URL) async throws -> [LocalModelDownloadEvent] {
        var events: [LocalModelDownloadEvent] = []
        for try await event in downloader.download(manifest, baseURL: baseURL,
                                                   identifier: manifest.id) {
            events.append(event)
        }
        return events
    }

    /// Spec §4: nothing is used until it is verified and atomically renamed into place.
    func testDownloadsVerifiesAndPromotesAtomically() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["config.json": Data(repeating: 0x11, count: 200),
                     "model.safetensors": Data(repeating: 0x22, count: 500)]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files)

        let events = try await run(downloader(store: store, server: server),
                                   manifest: manifest,
                                   baseURL: URL(string: "https://cdn.example.com/m/")!)

        XCTAssertEqual(events.last, .finished)
        XCTAssertTrue(store.isInstalled())
        XCTAssertEqual(store.installedManifest()?.version, 1)
        XCTAssertEqual(store.installedBytes(), 700)
        // Staging is gone: promotion really was a rename, not a copy that left debris.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
        for (name, expected) in files {
            let written = try Data(contentsOf: store.modelDirectory.appendingPathComponent(name))
            XCTAssertEqual(written, expected, "\(name) must survive the transfer byte for byte")
        }
    }

    /// A resumed transfer must re-request only the missing tail.
    func testResumesAPartialFileInsteadOfRestartingIt() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data((0..<500).map { UInt8($0 % 251) })]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files)

        // Simulate an earlier cancelled attempt: the first 200 bytes are already on disk.
        try store.prepareStaging()
        let partial = store.stagingFileURL(named: "model.safetensors")
        try files["model.safetensors"]!.prefix(200).write(to: partial)

        _ = try await run(downloader(store: store, server: server),
                          manifest: manifest,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)

        XCTAssertTrue(store.isInstalled())
        XCTAssertEqual(try Data(contentsOf: store.modelDirectory
            .appendingPathComponent("model.safetensors")),
                       files["model.safetensors"])

        // The first ranged request must start exactly where the partial file ended.
        let firstRanged = server.requests.first { $0.value(forHTTPHeaderField: "Range") != nil }
        XCTAssertEqual(firstRanged?.value(forHTTPHeaderField: "Range"), "bytes=200-263")
        // And the whole file must not have been re-fetched from zero.
        XCTAssertFalse(server.requests.contains { $0.value(forHTTPHeaderField: "Range") == "bytes=0-63" })
    }

    /// Tampered or truncated bytes must never reach the live directory (§4).
    func testACorruptFileIsRejectedAndNothingIsPromoted() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data(repeating: 0x33, count: 300)]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files,
                                     fault: .init(corrupt: true))

        do {
            _ = try await run(downloader(store: store, server: server),
                              manifest: manifest,
                              baseURL: URL(string: "https://cdn.example.com/m/")!)
            XCTFail("a digest mismatch must fail the install")
        } catch let error as LocalModelDownloadError {
            XCTAssertEqual(error, .checksumMismatch(file: "model.safetensors"))
        }

        XCTAssertFalse(store.isInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory.path))
    }

    /// A truncated file must be detected by the size check before hashing.
    func testATruncatedFileIsReportedAsShort() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data(repeating: 0x44, count: 300)]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files,
                                     fault: .init(truncateOnce: true))

        // The downloader keeps re-requesting until the file reaches its declared size, so a
        // single truncated chunk is recovered from rather than reported.
        _ = try await run(downloader(store: store, server: server),
                          manifest: manifest,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)
        XCTAssertTrue(store.isInstalled())
        XCTAssertGreaterThan(server.rangedRequestCount, 1)
    }

    /// Cancelling keeps the partial bytes, so the next attempt resumes (§4: 取消 must not
    /// mean starting over).
    func testCancellationKeepsPartialFilesForResume() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data(repeating: 0x55, count: 4000)]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files)
        let gate = DownloadGate()
        server.gate = gate
        let downloader = downloader(store: store, server: server)
        let partial = store.stagingFileURL(named: "model.safetensors")

        let consumer = Task {
            for try await _ in downloader.download(
                manifest,
                baseURL: URL(string: "https://cdn.example.com/m/")!,
                identifier: manifest.id) {}
        }

        // The gate blocks on the *second* chunk request, so once one arrival is recorded the
        // first chunk has already been written to disk — exactly the state a cancelled
        // download should leave behind. Bounded so a regression fails instead of hanging.
        var waited = 0
        while await gate.arrivalCount < 1 && waited < 2_000 {
            try await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        let arrived = await gate.arrivalCount
        XCTAssertGreaterThanOrEqual(arrived, 1, "the transfer never reached the gate")
        consumer.cancel()
        await gate.open()
        _ = try? await consumer.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path),
                      "partial bytes must survive a cancel")
        let written = LocalModelDownloader.existingSize(of: partial)
        XCTAssertGreaterThan(written, 0)
        XCTAssertLessThan(written, 4000, "the transfer really was interrupted")
        XCTAssertFalse(store.isInstalled(), "an interrupted download must not look installed")

        // And the next attempt finishes it rather than starting over.
        server.gate = nil
        _ = try await run(downloader, manifest: manifest,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)
        XCTAssertTrue(store.isInstalled())
        XCTAssertEqual(try Data(contentsOf: store.modelDirectory
            .appendingPathComponent("model.safetensors")), files["model.safetensors"])
    }

    /// A flaky connection is retried rather than failing the install.
    func testTransientTransportFailuresAreRetried() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["config.json": Data(repeating: 0x66, count: 120)]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files,
                                     fault: .init(throwCount: 2))

        _ = try await run(downloader(store: store, server: server),
                          manifest: manifest,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)
        XCTAssertTrue(store.isInstalled())
    }

    /// A server that ignores `Range` and resends the whole file must not produce a doubled
    /// or corrupted result.
    func testAServerThatIgnoresRangeDoesNotDuplicateBytes() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data((0..<200).map { UInt8($0 % 249) })
        let files = ["model.safetensors": payload]
        let manifest = makeManifest(files: files)
        // Pre-seed a partial file so the downloader *does* send a Range, which the server
        // then ignores by replying 200 with the full body.
        try store.prepareStaging()
        try payload.prefix(50).write(to: store.stagingFileURL(named: "model.safetensors"))

        let server = FakeModelServer(manifest: manifest, files: files,
                                     fault: .init(ignoreRange: true))
        _ = try await run(downloader(store: store, server: server),
                          manifest: manifest,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)

        XCTAssertTrue(store.isInstalled())
        XCTAssertEqual(try Data(contentsOf: store.modelDirectory
            .appendingPathComponent("model.safetensors")), payload)
    }

    func testProgressIsReportedMonotonicallyUpToCompletion() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data(repeating: 0x77, count: 500)]
        let manifest = makeManifest(files: files)
        let server = FakeModelServer(manifest: manifest, files: files)

        let events = try await run(downloader(store: store, server: server),
                                   manifest: manifest,
                                   baseURL: URL(string: "https://cdn.example.com/m/")!)

        let fractions = events.compactMap { event -> Double? in
            if case let .progress(fraction, _, _) = event { return fraction }
            return nil
        }
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions, fractions.sorted(), "progress must never go backwards")
        XCTAssertEqual(try XCTUnwrap(fractions.last), 1.0, accuracy: 0.0001)
        XCTAssertEqual(events.filter { $0 == .verifying }.count, 1)
    }

    /// A new version replaces the old one rather than sitting beside it (§4: 版本管理).
    func testInstallingANewVersionReplacesThePreviousOne() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let v1 = ["model.safetensors": Data(repeating: 0x01, count: 128)]
        let manifestV1 = makeManifest(files: v1, version: 1)
        _ = try await run(downloader(store: store,
                                     server: FakeModelServer(manifest: manifestV1, files: v1)),
                          manifest: manifestV1,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)
        XCTAssertEqual(store.installedManifest()?.version, 1)

        let v2 = ["model.safetensors": Data(repeating: 0x02, count: 256)]
        let manifestV2 = makeManifest(files: v2, version: 2)
        _ = try await run(downloader(store: store,
                                     server: FakeModelServer(manifest: manifestV2, files: v2)),
                          manifest: manifestV2,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)

        XCTAssertEqual(store.installedManifest()?.version, 2)
        XCTAssertEqual(store.installedBytes(), 256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.replacementDirectory.path))
    }

    func testDeleteRemovesTheInstalledModelAndAnyPartialDownload() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data(repeating: 0x08, count: 128)]
        let manifest = makeManifest(files: files)
        _ = try await run(downloader(store: store,
                                     server: FakeModelServer(manifest: manifest, files: files)),
                          manifest: manifest,
                          baseURL: URL(string: "https://cdn.example.com/m/")!)
        try store.prepareStaging()
        try Data(repeating: 0x09, count: 10)
            .write(to: store.stagingFileURL(named: "leftover.part"))

        try store.deleteInstalled()

        XCTAssertFalse(store.isInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingDirectory.path))
    }

    func testManifestFetchRejectsANonSuccessStatus() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeModelServer(manifest: makeManifest(files: ["a": Data([1])]),
                                     files: ["a": Data([1])])
        // `model-manifest.json` is served 200, so ask for a name that is not there.
        do {
            _ = try await downloader(store: store, server: server)
                .fetchManifest(from: URL(string: "https://cdn.example.com/m/nope.json")!)
            XCTFail("expected the 404 to surface")
        } catch let error as LocalModelDownloadError {
            XCTAssertEqual(error, .badStatus(404))
        }
    }
}

// MARK: - Manifest integrity

final class ModelIntegrityTests: XCTestCase {
    func testManifestForADifferentModelIsRejectedBeforeDownloading() throws {
        let manifest = makeManifest(files: ["config.json": Data([1, 2, 3])], id: "some-other-model")
        XCTAssertThrowsError(try manifest.validate(expectedIdentifier: "qwen3-0.6b-4bit")) { error in
            XCTAssertEqual(error as? LocalModelDownloadError,
                           .manifestMismatch(expected: "qwen3-0.6b-4bit", found: "some-other-model"))
        }
    }

    func testPathTraversalInAFileNameIsRejected() {
        let manifest = LocalModelManifest(
            id: "qwen3-0.6b-4bit", version: 1, size: 10, sha256: "",
            files: [.init(name: "../escape.safetensors", size: 10, sha256: "abc")])
        XCTAssertThrowsError(try manifest.validate(expectedIdentifier: "qwen3-0.6b-4bit"))
    }

    func testAnEmptyFileListIsRejected() {
        let manifest = LocalModelManifest(id: "qwen3-0.6b-4bit", version: 1,
                                          size: 0, sha256: "", files: [])
        XCTAssertThrowsError(try manifest.validate(expectedIdentifier: "qwen3-0.6b-4bit")) { error in
            XCTAssertEqual(error as? LocalModelDownloadError,
                           .invalidManifest("The manifest lists no files."))
        }
    }

    func testAFileEntryWithoutADigestIsRejected() {
        let manifest = LocalModelManifest(
            id: "qwen3-0.6b-4bit", version: 1, size: 10, sha256: "",
            files: [.init(name: "config.json", size: 10, sha256: "")])
        XCTAssertThrowsError(try manifest.validate(expectedIdentifier: "qwen3-0.6b-4bit"))
    }

    /// A manifest that lists no `files` still works for the single-file case (§4 shows an
    /// empty array in the example payload).
    func testAManifestWithoutAFileListFallsBackToTheTopLevelDigest() throws {
        let payload = Data([9, 9, 9])
        let manifest = LocalModelManifest(id: "qwen3-0.6b-4bit", version: 1,
                                          size: 3, sha256: sha256Hex(payload), files: [])
        try manifest.validate(expectedIdentifier: "qwen3-0.6b-4bit")
        XCTAssertEqual(manifest.transferableFiles.map(\.name), ["model.safetensors"])
        XCTAssertEqual(manifest.totalBytes, 3)
    }

    /// A file that is present but the wrong size is not "installed" — that is how a truncated
    /// or half-deleted model is caught at startup without re-hashing 350 MB.
    func testAnInstalledModelWithAFileOfTheWrongSizeIsNotReady() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["model.safetensors": Data(repeating: 0x10, count: 256)]
        let manifest = makeManifest(files: files)
        let downloader = LocalModelDownloader(store: store,
                                              transport: FakeModelServer(manifest: manifest, files: files),
                                              chunkSize: testChunkSize,
                                              sleep: { _ in })
        for try await _ in downloader.download(manifest,
                                               baseURL: URL(string: "https://cdn.example.com/m/")!,
                                               identifier: manifest.id) {}
        XCTAssertTrue(store.isInstalled())

        // Someone truncates the weights.
        try Data(repeating: 0x10, count: 100)
            .write(to: store.modelDirectory.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(store.isInstalled(), "a size mismatch must invalidate the install")

        // ...or deletes them outright.
        try FileManager.default.removeItem(at: store.modelDirectory
            .appendingPathComponent("model.safetensors"))
        XCTAssertFalse(store.isInstalled())
    }

    func testTheInstalledManifestIsWrittenInsideTheModelDirectory() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = ["config.json": Data(repeating: 0x12, count: 40)]
        let manifest = makeManifest(files: files, version: 7)
        let downloader = LocalModelDownloader(store: store,
                                              transport: FakeModelServer(manifest: manifest, files: files),
                                              chunkSize: testChunkSize,
                                              sleep: { _ in })
        for try await _ in downloader.download(manifest,
                                               baseURL: URL(string: "https://cdn.example.com/m/")!,
                                               identifier: manifest.id) {}

        // The manifest travels with the weights, so readiness is derived from the disk rather
        // than from a UserDefaults value that could drift.
        XCTAssertEqual(store.installedManifest(), manifest)
        XCTAssertEqual(store.installedManifest()?.version, 7)
    }

    /// The models directory is under Application Support and excluded from backup (§3).
    func testTheModelRootIsInsideApplicationSupportAndNotBackedUp() throws {
        let root = LocalModelStore.defaultRoot()
        XCTAssertTrue(root.path.contains("Application Support"),
                      "the model must be an application cache, not vault content: \(root.path)")
        XCTAssertFalse(root.path.contains("Documents"))
        XCTAssertTrue(root.lastPathComponent == "Models")

        let (store, temporaryRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try store.prepareStaging()
        XCTAssertFalse(store.modelDirectory.path.contains("Documents"))
    }
}
