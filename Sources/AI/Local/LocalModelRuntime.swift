import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the local model in memory only while it is being used (China plan §26).
///
/// Loading 350 MB of weights is slow and memory-hungry, so it must never happen at launch.
/// The lifecycle is: first capture triggers a load → the engine is reused for a short idle
/// window → memory pressure or backgrounding unloads it. Everything that touches the loaded
/// engine is funnelled through this actor, which also matches MLX's own requirement that the
/// model not be driven from several tasks at once.
actor LocalModelRuntime {
    static let shared = LocalModelRuntime()

    /// How long an unused model stays resident. Long enough to make a burst of captures fast,
    /// short enough that a backgrounded app is not holding hundreds of megabytes.
    static let defaultIdleTimeout: TimeInterval = 120

    private struct Loaded {
        let directory: URL
        let engine: any LocalTextGenerating
        var lastUsedAt: Date
    }

    private var loaded: Loaded?
    /// The load currently running, so callers that arrive during it share one trip to disk.
    private var inFlight: Task<Loaded, Error>?
    private var inFlightDirectory: URL?
    /// Bumped by `unload` so a load that finishes after the weights were dropped cannot quietly
    /// put them back, which would defeat the memory-pressure guarantee of §26.
    private var loadGeneration: UInt64 = 0
    private var observers: [any NSObjectProtocol] = []
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private let engineFactory: @Sendable (URL) async throws -> any LocalTextGenerating
    private let idleTimeout: TimeInterval

    init(engineFactory: @escaping @Sendable (URL) async throws -> any LocalTextGenerating
            = LocalModelRuntime.defaultEngineFactory(),
         idleTimeout: TimeInterval = LocalModelRuntime.defaultIdleTimeout) {
        self.engineFactory = engineFactory
        self.idleTimeout = idleTimeout
    }

    /// The real MLX engine when this build links it; otherwise a factory that refuses, so a
    /// model file that somehow exists on disk still degrades to Local Lite instead of
    /// crashing or reaching for the network.
    static func defaultEngineFactory() -> @Sendable (URL) async throws -> any LocalTextGenerating {
        guard isRuntimeLinked else {
            return { _ in
                throw LocalAIError.modelUnavailable(
                    String(localized: "This build does not include the on-device runtime."))
            }
        }
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(Tokenizers)
        return { directory in try await MLXQwenEngine.load(modelDirectory: directory) }
        #else
        return { _ in
            throw LocalAIError.modelUnavailable(
                String(localized: "This build does not include the on-device runtime."))
        }
        #endif
    }

    /// Whether this build can run the local model at all. Settings uses this to decide
    /// whether offering a 350 MB download even makes sense.
    static var isRuntimeLinked: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(Tokenizers)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Loading

    /// Returns a loaded engine, loading it on first use and reusing it while it stays warm.
    func engine(for directory: URL) async throws -> any LocalTextGenerating {
        if var current = loaded, current.directory == directory {
            current.lastUsedAt = Date()
            loaded = current
            return current.engine
        }

        // Join the load already running for this directory rather than starting a second one.
        //
        // This method suspends at `await task.value`, which releases the actor, so without
        // single-flight tracking two callers both observe "nothing loaded" and both build the
        // weights. That is not hypothetical: preloading exists to warm the model for a capture,
        // so the two are routinely in flight together. Measured before this guard: **two engine
        // constructions for one model** — twice the memory and the disk read, on the very path
        // that was supposed to save time.
        let task: Task<Loaded, Error>
        let generation: UInt64
        if let existing = inFlight, inFlightDirectory == directory {
            task = existing
            generation = loadGeneration
        } else {
            // A different model directory means the old weights are useless.
            inFlight?.cancel()
            loaded = nil
            let factory = engineFactory
            generation = loadGeneration
            task = Task {
                let engine = try await factory(directory)
                return Loaded(directory: directory, engine: engine, lastUsedAt: Date())
            }
            inFlight = task
            inFlightDirectory = directory
        }

        /// True while the result we just waited for is still the one that owns `loaded`.
        func stillOwnsTheSlot() -> Bool {
            inFlightDirectory == directory && generation == loadGeneration
        }

        do {
            let result = try await task.value
            // Publish only if the weights were not dropped (or replaced) while this load ran —
            // otherwise a memory-pressure unload would be silently undone by the load it raced.
            if stillOwnsTheSlot() {
                loaded = result
                inFlight = nil
                inFlightDirectory = nil
            }
            // The caller still gets a usable engine either way; the capture must not fail just
            // because the cache was asked to let go.
            return result.engine
        } catch {
            if stillOwnsTheSlot() {
                inFlight = nil
                inFlightDirectory = nil
            }
            throw error
        }
    }

    /// Drops the weights. Safe to call at any time; the next capture reloads them.
    func unload() {
        loaded = nil
        // A load that is already running must not repopulate `loaded` after we were asked to let
        // the memory go — that is the whole point of the memory-pressure and background hooks.
        loadGeneration &+= 1
        inFlight = nil
        inFlightDirectory = nil
    }

    /// Loads the weights ahead of the capture that will need them.
    ///
    /// The first capture after launch is the slow one — it pays the load (1.2–1.7 s measured on
    /// an iPhone 15 Pro) *and* the generation. Warming the engine while the user is still
    /// getting to the capture removes the load from the critical path entirely.
    ///
    /// Deliberately not called at launch (§26 forbids pinning memory before the user shows any
    /// intent) and deliberately failure-tolerant: a preload that fails must leave the capture
    /// path to report the real error, so this returns nothing.
    @discardableResult
    func preload(directory: URL) async -> Bool {
        await unloadIfIdle()
        guard loaded?.directory != directory else { return true }
        do {
            _ = try await engine(for: directory)
            return true
        } catch {
            return false
        }
    }

    /// Unloads if nothing has used the model for `idleTimeout`. Called before a load so a
    /// stale engine does not sit in memory across a long idle period.
    func unloadIfIdle(now: Date = Date()) {
        guard let current = loaded else { return }
        guard now.timeIntervalSince(current.lastUsedAt) > idleTimeout else { return }
        loaded = nil
    }

    var isLoaded: Bool { loaded != nil }

    // MARK: - System pressure (spec §26)

    /// Starts observing memory warnings and backgrounding. Idempotent.
    func startObservingSystemPressure() {
        guard observers.isEmpty, memoryPressureSource == nil else { return }
        let center = NotificationCenter.default

        #if os(iOS)
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil,
                                            queue: nil) { [weak self] _ in
            Task { await self?.unload() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil,
                                            queue: nil) { [weak self] _ in
            Task { await self?.unload() }
        })
        #else
        // macOS has no memory-warning notification; the kernel's pressure source is the
        // equivalent signal, and it fires before the system starts swapping.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.unload() }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    func stopObservingSystemPressure() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    /// Wraps this runtime as a `NoteGenerating` provider for one capture.
    ///
    /// The body style is read from settings here, at the one place a provider is built, so the
    /// router and the coordinator stay unaware of it.
    nonisolated func provider(modelDirectory: URL,
                              profiles: [CategoryProfile]) -> any NoteGenerating {
        let raw = UserDefaults.standard.string(forKey: ClipNestSettings.localBodyStyle)
        let bodyStyle = raw.flatMap(LocalBodyStyle.init(rawValue:)) ?? .default
        return QwenLocalProvider(engine: RuntimeBackedLocalEngine(runtime: self,
                                                                 modelDirectory: modelDirectory),
                                 profiles: profiles,
                                 promptBuilder: LocalPromptBuilder(bodyStyle: bodyStyle))
    }
}

/// Adapts the actor-isolated runtime to the synchronous `LocalTextGenerating` protocol: the
/// heavy load happens on first `generate`, not when the provider is constructed.
struct RuntimeBackedLocalEngine: LocalTextStreaming, LocalTextPreparing {
    let runtime: LocalModelRuntime
    let modelDirectory: URL

    var engineName: String { LocalModelDescriptor.qwen3.displayName }

    var isPrepared: Bool {
        get async { await runtime.isLoaded }
    }

    func prepare() async {
        await runtime.unloadIfIdle()
        _ = try? await runtime.engine(for: modelDirectory)
    }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        try await generate(prompt: prompt, maximumTokens: maximumTokens) { _ in }
    }

    func generate(prompt: String,
                  maximumTokens: Int,
                  onDelta: @Sendable (String) -> Void) async throws -> String {
        await runtime.unloadIfIdle()
        let engine = try await runtime.engine(for: modelDirectory)
        guard let streaming = engine as? LocalTextStreaming else {
            return try await engine.generate(prompt: prompt, maximumTokens: maximumTokens)
        }
        return try await streaming.generate(prompt: prompt,
                                            maximumTokens: maximumTokens,
                                            onDelta: onDelta)
    }
}
