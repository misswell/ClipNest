import Foundation

/// Where a capture's intelligence comes from (China plan §8, §16).
///
/// Only two modes exist, and the difference between them is a privacy boundary rather
/// than a performance preference:
///
/// - `local` processes everything on the device. No URLSession, no OpenAI provider, no
///   remote search — not even when the local model fails.
/// - `online` uses the configured OpenAI-compatible endpoint.
///
/// There is deliberately no `automatic` mode: "prefer local, silently fall back to the
/// network" is exactly the behaviour that makes a privacy promise untrustworthy.
enum AIProcessingMode: String, CaseIterable, Identifiable {
    case local
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return String(localized: "On-Device")
        case .online: return String(localized: "Online")
        }
    }

    var description: String {
        switch self {
        case .local:
            return String(localized: "Content never leaves this device.")
        case .online:
            return String(localized: "Use the AI service you configured.")
        }
    }

    /// The recommended default (spec §8). Local is the default so a fresh install is
    /// private and offline-capable without any configuration.
    static let recommended: AIProcessingMode = .local
}

/// Everything the router needs to pick a provider. Loaded once per capture so the
/// coordinator never has to know about the local model or OpenAI.
struct GenerationConfiguration: Equatable {
    var mode: AIProcessingMode
    var text: AIConfiguration
    var image: AIImageConfiguration

    static func load() -> GenerationConfiguration {
        GenerationConfiguration(mode: AIConfigurationStore.loadProcessingMode(),
                                text: AIConfigurationStore.load(),
                                image: AIConfigurationStore.loadImageConfiguration())
    }
}
