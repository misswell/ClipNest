import XCTest
@testable import ClipNest

/// A stand-in engine whose creation is slow enough to interleave with a second caller.
private struct SlowEngine: LocalTextGenerating {
    let engineName = "Slow"
    func generate(prompt: String, maximumTokens: Int) async throws -> String { "{}" }
}

/// Counts how many times weights were actually built, so a double load is observable.
private final class FactoryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// §26 lifecycle: the loaded engine must be built once and reused. Preloading exists to take the
/// load off the capture's critical path, which means the preload and the capture it is warming for
/// can be in flight **at the same time** — so "load once" has to survive concurrency, not just
/// sequential reuse.
final class LocalModelRuntimeConcurrencyTests: XCTestCase {
    private func makeRuntime(_ counter: FactoryCallCounter) -> LocalModelRuntime {
        LocalModelRuntime(
            engineFactory: { _ in
                counter.increment()
                // Long enough that a second caller arrives while this is still running.
                try? await Task.sleep(nanoseconds: 120_000_000)
                return SlowEngine()
            },
            idleTimeout: 120)
    }

    /// The hazard: `engine(for:)` suspends at its `await`, which releases the actor. A preload
    /// racing the capture would then both see "nothing loaded" and both build 350 MB of weights —
    /// two engines, double the memory, on the very path that was supposed to save time.
    func testConcurrentLoadsBuildTheWeightsOnlyOnce() async throws {
        let counter = FactoryCallCounter()
        let runtime = makeRuntime(counter)
        let directory = URL(fileURLWithPath: "/tmp/ClipNestTestModel")

        async let first = runtime.engine(for: directory)
        async let second = runtime.engine(for: directory)
        _ = try await (first, second)

        XCTAssertEqual(counter.calls, 1,
                       "a preload racing a capture must join the same load, not start a second")
    }

    /// The same race reached through the public preload entry point, which is how the capture
    /// path and the scene-active warm-up actually meet.
    func testPreloadRacingACaptureBuildsTheWeightsOnlyOnce() async throws {
        let counter = FactoryCallCounter()
        let runtime = makeRuntime(counter)
        let directory = URL(fileURLWithPath: "/tmp/ClipNestTestModel")

        async let preload = runtime.preload(directory: directory)
        async let capture = runtime.engine(for: directory)
        _ = try await (preload, capture)

        XCTAssertEqual(counter.calls, 1,
                       "preload must not duplicate the load the capture is already doing")
    }

    /// Sequential reuse still has to hit the cache — the original §26 guarantee.
    func testASecondCallAfterTheFirstReusesTheEngine() async throws {
        let counter = FactoryCallCounter()
        let runtime = makeRuntime(counter)
        let directory = URL(fileURLWithPath: "/tmp/ClipNestTestModel")

        _ = try await runtime.engine(for: directory)
        _ = try await runtime.engine(for: directory)

        XCTAssertEqual(counter.calls, 1)
    }

    /// Switching model directories must not hand back the old weights.
    func testADifferentDirectoryLoadsItsOwnEngine() async throws {
        let counter = FactoryCallCounter()
        let runtime = makeRuntime(counter)

        _ = try await runtime.engine(for: URL(fileURLWithPath: "/tmp/ModelA"))
        _ = try await runtime.engine(for: URL(fileURLWithPath: "/tmp/ModelB"))

        XCTAssertEqual(counter.calls, 2)
    }

    /// A failed load must not be remembered as loaded, and must be retryable.
    func testAFailedLoadIsNotCached() async throws {
        let counter = FactoryCallCounter()
        let runtime = LocalModelRuntime(
            engineFactory: { _ in
                counter.increment()
                throw LocalAIError.modelUnavailable("no model")
            },
            idleTimeout: 120)
        let directory = URL(fileURLWithPath: "/tmp/ClipNestTestModel")

        for _ in 0..<2 {
            do {
                _ = try await runtime.engine(for: directory)
                XCTFail("the factory always throws")
            } catch {
                // expected
            }
        }

        let stillLoaded = await runtime.isLoaded
        XCTAssertFalse(stillLoaded)
    }

    /// §26: memory pressure drops the weights, and the next call rebuilds them.
    func testUnloadForcesAReloadAndTheNextCallRebuilds() async throws {
        let counter = FactoryCallCounter()
        let runtime = makeRuntime(counter)
        let directory = URL(fileURLWithPath: "/tmp/ClipNestTestModel")

        _ = try await runtime.engine(for: directory)
        await runtime.unload()
        _ = try await runtime.engine(for: directory)

        XCTAssertEqual(counter.calls, 2)
    }

    /// A preload must never throw into the capture path: if it fails, the capture reports the
    /// real error itself.
    func testAFailingPreloadReportsFailureWithoutThrowing() async {
        let runtime = LocalModelRuntime(
            engineFactory: { _ in throw LocalAIError.modelUnavailable("no model") },
            idleTimeout: 120)

        let warmed = await runtime.preload(directory: URL(fileURLWithPath: "/tmp/ClipNestTestModel"))

        XCTAssertFalse(warmed)
    }
}
