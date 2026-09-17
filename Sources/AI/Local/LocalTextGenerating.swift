import Foundation

/// The seam between ClipNest and whatever actually runs the local weights (China plan §15, §18).
///
/// Everything above this protocol — routing, prompting, decoding, degradation to Local Lite,
/// the privacy boundary — is ordinary Swift that can be tested without MLX, a GPU, or a
/// 350 MB download. Only the conforming type needs MLX.
protocol LocalTextGenerating: Sendable {
    /// Shown in Settings and logs, e.g. "Qwen3 0.6B".
    var engineName: String { get }

    /// Runs one completion. Implementations must not reach the network: the model is
    /// already on disk by the time this is called.
    func generate(prompt: String, maximumTokens: Int) async throws -> String
}

/// An engine that can hand over its answer **while it is still being written**.
///
/// Kept separate from `LocalTextGenerating` on purpose: streaming is a capability, not a
/// requirement. Local Lite and the scripted test engines have no tokens to stream, and the
/// provider already knows how to run without it — so adding this as a second protocol avoids
/// forcing every conformer to invent a no-op implementation.
protocol LocalTextStreaming: LocalTextGenerating {
    /// Runs one completion, calling `onDelta` with the **whole answer so far** each time more
    /// arrives, and returns the same final string `generate` would have.
    ///
    /// Passing the accumulated text rather than a fragment keeps the caller free of
    /// reassembly bugs, and the cost is trivial at these sizes (a few hundred characters).
    func generate(prompt: String,
                  maximumTokens: Int,
                  onDelta: @Sendable (String) -> Void) async throws -> String
}

/// An engine that has to be brought into memory before it can run.
///
/// `prepare` exists for two callers with the same need: the capture path, so the UI can show
/// "preparing the model" as a distinct phase instead of a spinner that looks identical to
/// "thinking"; and the preload path, so the first capture after launch does not pay the load.
/// Both are the same call — the only difference is who makes it and when.
protocol LocalTextPreparing: Sendable {
    /// Loads the engine if it is not already resident. Cheap and free of side effects when the
    /// engine is warm, so calling it speculatively is safe.
    func prepare() async

    /// `true` when the weights are already in memory and a capture would not pay a load.
    var isPrepared: Bool { get async }
}

/// A `LocalTextGenerating` that is deliberately broken, for tests that need "a model is
/// installed but this run failed".
struct FailingLocalTextEngine: LocalTextGenerating {
    let engineName = "Failing Engine"
    var error: any Error = LocalAIError.generationFailed("test")

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        throw error
    }
}

/// A deterministic stand-in used by tests and previews.
struct ScriptedLocalTextEngine: LocalTextGenerating {
    var engineName = "Scripted Engine"
    var response: String
    var error: (any Error)?

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        if let error { throw error }
        return response
    }
}
