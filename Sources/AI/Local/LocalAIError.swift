import Foundation

/// Failures on the local generation path.
///
/// The distinction that matters for the China plan is not "can we retry online" — local
/// mode never has a network fallback — but whether the failure is *expected* (no model
/// installed, the device cannot run it) or a real error worth surfacing. Expected states
/// resolve to Local Lite with no user-visible error; genuine failures keep the note and
/// degrade to Local Lite as well, but are reported so the user can see something is wrong.
enum LocalAIError: LocalizedError {
    /// No local model is installed or it cannot run on this device.
    ///
    /// This is a normal, expected state — ClipNest is designed to work without any
    /// downloaded model — so it is never presented as an error.
    case modelUnavailable(String)
    /// A model is installed but this run failed (out of memory, corrupt file, bad output).
    case generationFailed(String)
    /// Nothing readable was found in the input.
    case emptyInput

    var errorDescription: String? {
        switch self {
        case let .modelUnavailable(reason):
            return String(localized: "On-device AI is unavailable: \(reason)")
        case let .generationFailed(reason):
            return String(localized: "On-device AI could not finish: \(reason)")
        case .emptyInput:
            return String(localized: "There is no content to organize.")
        }
    }

    /// Whether the local engine asked for a *retryable* degradation rather than a bail-out.
    ///
    /// `modelUnavailable` means Local Lite should take over silently. The other two mean
    /// Local Lite takes over too, but the reason is worth logging.
    var isExpectedAbsence: Bool {
        if case .modelUnavailable = self { return true }
        return false
    }
}
