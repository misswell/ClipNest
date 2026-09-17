#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(Tokenizers)
import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Runs Qwen3-0.6B-4bit on Apple silicon through MLX (China plan §18, §21, §23).
///
/// This is the only file in the app that knows MLX exists. Everything above it — routing,
/// prompting, JSON tolerance, degradation to Local Lite, the settings UI — is plain Swift, so
/// the feature can be reasoned about and tested without a GPU or a 350 MB download.
///
/// Two properties are enforced here rather than trusted:
///
/// - **No network.** Loading goes through `loadModelContainer(from:using:)`, which takes no
///   `Downloader` at all — there is no code path from this type to a remote model. The weights
///   are already on disk, placed there by `LocalModelDownloader` from the configured CDN.
/// - **No photo ever reaches the model.** This type only accepts text; images are recognized by
///   Vision OCR first (§23), which is also why a 0.6B text model is enough.
///
/// It is an `actor` so that two captures can never drive the same MLX container at once, which
/// MLX does not support.
actor MLXQwenEngine: LocalTextStreaming {
    nonisolated let engineName: String

    private let container: ModelContainer

    /// Organizing and extracting is not creative writing: a low temperature keeps the model
    /// from inventing detail that is not in the source (§20).
    private static let temperature: Float = 0.2
    private static let topP: Float = 0.9


    private init(container: ModelContainer, name: String) {
        self.container = container
        self.engineName = name
    }

    /// Loads the weights from a local directory. Slow and memory-hungry, which is why
    /// `LocalModelRuntime` calls it on demand and unloads afterwards (§26).
    static func load(modelDirectory: URL) async throws -> MLXQwenEngine {
        // A missing or truncated directory is a normal "not installed" state, not a crash.
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw LocalAIError.modelUnavailable(
                String(localized: "The model files are no longer on disk."))
        }
        do {
            let container = try await loadModelContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader())
            return MLXQwenEngine(container: container,
                                 name: LocalModelDescriptor.qwen3.displayName)
        } catch let error as LocalAIError {
            throw error
        } catch {
            throw LocalAIError.generationFailed(
                String(localized: "Could not load the on-device model: \(error.localizedDescription)"))
        }
    }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        try await generateWithMetrics(prompt: prompt, maximumTokens: maximumTokens).text
    }

    /// Streams the answer as it is written, so the capture UI can show progress instead of a
    /// spinner that says nothing for several seconds.
    ///
    /// `onDelta` receives the accumulated text (see `LocalTextStreaming`). Callbacks are
    /// coalesced by character count rather than fired per model token: a 0.6B model at ~40 tok/s
    /// produces chunks far faster than a view can redraw, and a preview that updates on every
    /// token would spend more time in layout than in the model.
    func generate(prompt: String,
                  maximumTokens: Int,
                  onDelta: @Sendable (String) -> Void) async throws -> String {
        let parameters = GenerateParameters(maxTokens: maximumTokens,
                                           temperature: Self.temperature,
                                           topP: Self.topP)
        let session = ChatSession(container,
                                  generateParameters: parameters,
                                  additionalContext: LocalPromptBuilder.chatTemplateContext)
        do {
            var text = ""
            for try await generation in session.streamDetails(to: prompt) {
                guard case .chunk(let chunk) = generation else { continue }
                text += chunk
                // Every chunk is forwarded. The library already coalesces tokens into
                // detokenised segments, so these are far rarer than one per token — measured
                // at a handful per generation — and a stride on top of that only made the
                // preview update less often for no saving.
                onDelta(text)
            }
            onDelta(text)
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalAIError.generationFailed(error.localizedDescription)
        }
    }


    /// The same call, plus where the time went.
    ///
    /// The streaming API is used purely so the library's own completion info — prompt tokens,
    /// prefill time, decode time — is available. The text is assembled identically, so the
    /// result is the same string `respond(to:)` would have returned.
    func generateWithMetrics(prompt: String,
                             maximumTokens: Int) async throws -> (text: String,
                                                                  metrics: LocalGenerationMetrics?) {
        // A fresh session per note: two captures must not share conversation state.
        let parameters = GenerateParameters(maxTokens: maximumTokens,
                                           temperature: Self.temperature,
                                           topP: Self.topP)
        // §21: thinking must be *off*, not merely discouraged. Qwen3's chat template reads
        // `enable_thinking` from the template context, so this is the switch that actually
        // works. Measured on the real weights: a `/no_think` line in the prompt text is not
        // honoured by this model and it still emitted a ` thinking` block, which then leaked
        // into the raw answer.
        let session = ChatSession(container,
                                  generateParameters: parameters,
                                  additionalContext: LocalPromptBuilder.chatTemplateContext)
        do {
            var text = ""
            var metrics: LocalGenerationMetrics?
            for try await generation in session.streamDetails(to: prompt) {
                switch generation {
                case .chunk(let chunk):
                    text += chunk
                case .info(let info):
                    metrics = LocalGenerationMetrics(
                        promptTokens: info.promptTokenCount,
                        generatedTokens: info.generationTokenCount,
                        prefillSeconds: info.promptTime,
                        decodeSeconds: info.generateTime)
                case .toolCall:
                    break
                }
            }
            return (text, metrics)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalAIError.generationFailed(error.localizedDescription)
        }
    }
}
#endif
