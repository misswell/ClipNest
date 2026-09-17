import XCTest
@testable import ClipNest

/// Objective ①, the decision half: *when* should the model be warmed?
///
/// The rule matters because it is the difference between removing a 1.35 s load from the first
/// paste and either warming a model nobody asked for or doing it in a mode that has no local
/// model at all. `CaptureCoordinator` takes the action as a closure, so this exercises the real
/// method body without MLX, a 350 MB model, or global user defaults.
@MainActor
final class LocalModelPreloadDecisionTests: XCTestCase {
    /// Counts warm-ups so "did it preload?" is observable.
    private final class WarmUpCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func makeDefaults(preload: Bool?) -> UserDefaults {
        let suite = "ClipNestPreloadTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let preload {
            defaults.set(preload, forKey: ClipNestSettings.localModelPreload)
        }
        return defaults
    }

    private func makeCoordinator(defaults: UserDefaults,
                                 counter: WarmUpCounter) -> CaptureCoordinator {
        CaptureCoordinator(store: VaultStore(),
                           clipboardService: QuietClipboard(),
                           noteGenerator: nil,
                           defaults: defaults,
                           preloadLocalModel: { counter.record() })
    }

    func testLocalModeWithTheSettingOnWarmsTheModel() {
        let counter = WarmUpCounter()
        let coordinator = makeCoordinator(defaults: makeDefaults(preload: true), counter: counter)

        coordinator.preloadLocalModelIfEnabled(mode: .local)

        XCTAssertEqual(counter.calls, 1)
    }

    /// "Keep the model ready" is a switch the user can turn off; off must mean off.
    func testLocalModeWithTheSettingOffDoesNotWarmTheModel() {
        let counter = WarmUpCounter()
        let coordinator = makeCoordinator(defaults: makeDefaults(preload: false), counter: counter)

        coordinator.preloadLocalModelIfEnabled(mode: .local)

        XCTAssertEqual(counter.calls, 0)
    }

    /// A fresh install has no stored value, and the documented default is *on* — the whole point
    /// is that the first paste after launch is fast without the user finding a setting first.
    func testAFreshInstallWarmsTheModelByDefault() {
        let counter = WarmUpCounter()
        let coordinator = makeCoordinator(defaults: makeDefaults(preload: nil), counter: counter)

        coordinator.preloadLocalModelIfEnabled(mode: .local)

        XCTAssertEqual(counter.calls, 1)
    }

    /// §11: an online configuration has no local model, and warming one would be a step towards
    /// needing the network in a mode that must not.
    func testAnOnlineModeNeverWarmsALocalModel() {
        let counter = WarmUpCounter()
        let coordinator = makeCoordinator(defaults: makeDefaults(preload: true), counter: counter)

        for mode in AIProcessingMode.allCases where mode != .local {
            coordinator.preloadLocalModelIfEnabled(mode: mode)
        }

        XCTAssertEqual(counter.calls, 0)
    }

    /// Turning the setting off must win over every mode, including local.
    func testTheSettingOffWinsInEveryMode() {
        let counter = WarmUpCounter()
        let coordinator = makeCoordinator(defaults: makeDefaults(preload: false), counter: counter)

        for mode in AIProcessingMode.allCases {
            coordinator.preloadLocalModelIfEnabled(mode: mode)
        }

        XCTAssertEqual(counter.calls, 0)
    }
}

/// Minimal clipboard stub so the coordinator can be built without the real pasteboard.
private final class QuietClipboard: ClipboardProviding {
    func changeCount() -> Int { 0 }
    func readCurrent() -> ClipboardSnapshot? { nil }
}
