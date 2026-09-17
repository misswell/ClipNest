import Foundation

/// Where a local generation actually spent its time.
///
/// Decode and prefill have completely different costs, and they scale with different things:
/// prefill grows with the prompt (the rules plus the captured text), decode grows with how
/// much the model writes. Optimising the wrong one wastes effort, so the engine reports both
/// rather than only a wall-clock total.
struct LocalGenerationMetrics: Equatable, Sendable {
    /// Tokens in the prompt — the instruction block plus the source text.
    var promptTokens: Int
    /// Tokens the model actually emitted.
    var generatedTokens: Int
    /// Time to first token.
    var prefillSeconds: Double
    /// Time to generate everything after the first token.
    var decodeSeconds: Double

    var tokensPerSecond: Double {
        decodeSeconds > 0 ? Double(generatedTokens) / decodeSeconds : 0
    }

    var promptTokensPerSecond: Double {
        prefillSeconds > 0 ? Double(promptTokens) / prefillSeconds : 0
    }

    var totalSeconds: Double { prefillSeconds + decodeSeconds }

    var summary: String {
        """
        prompt \(promptTokens) tok in \(Self.seconds(prefillSeconds)) \
        (\(Int(promptTokensPerSecond)) tok/s) · \
        generated \(generatedTokens) tok in \(Self.seconds(decodeSeconds)) \
        (\(Int(tokensPerSecond)) tok/s)
        """
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }
}
