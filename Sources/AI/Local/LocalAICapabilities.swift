import Foundation
import NaturalLanguage
import Vision

/// What this install can actually do locally (China plan §30).
///
/// Shown verbatim in Settings so a user never has to guess why "local AI" behaved a certain
/// way — in particular, that OCR and basic organizing work with nothing downloaded, no API
/// key, and no network.
struct LocalAICapabilities: Equatable {
    enum Status: Equatable {
        case available
        case unavailable(String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var detail: String {
            switch self {
            case .available: return String(localized: "Available")
            case let .unavailable(reason): return reason
            }
        }
    }

    /// Apple Vision text recognition. On every supported OS version, needs no download.
    let visionOCR: Status
    /// ClipNest Local Lite: extractive title/summary/tags/classification. Always present.
    let localNoteEngine: Status
    /// The optional downloaded Qwen3-0.6B model.
    let enhancedModel: Status
    /// `NLEmbedding` sentence embeddings, used by the smart-search layer.
    let sentenceEmbedding: Status
    /// Human-readable name of whichever local generator will actually run.
    let localNoteEngineName: String

    static func current(store: LocalModelStore = LocalModelStore()) -> LocalAICapabilities {
        let enhanced = enhancedModelStatus(store: store)
        return LocalAICapabilities(
            visionOCR: visionStatus(),
            localNoteEngine: .available,
            enhancedModel: enhanced,
            sentenceEmbedding: sentenceEmbeddingStatus(),
            localNoteEngineName: enhanced.isAvailable
                ? LocalModelDescriptor.qwen3.displayName
                : LocalLiteNoteProvider.engineName
        )
    }

    /// Reports the downloaded model. Four distinct states matter to the user: this device
    /// cannot run it, this build has no runtime, the model is not installed, or it is ready.
    static func enhancedModelStatus(store: LocalModelStore = LocalModelStore()) -> Status {
        guard LocalModelStore.isHardwareCapable else {
            return .unavailable(String(localized: "Requires an Apple silicon Mac"))
        }
        guard LocalModelRuntime.isRuntimeLinked else {
            return .unavailable(String(localized: "Not included in this build"))
        }
        guard store.isInstalled() else {
            return .unavailable(String(localized: "Not downloaded"))
        }
        return .available
    }

    private static func visionStatus() -> Status {
        let supported = VisionOCRService.supportedLanguages()
        return supported.isEmpty
            ? .unavailable(String(localized: "No recognition languages installed"))
            : .available
    }

    private static func sentenceEmbeddingStatus() -> Status {
        let languages = LocalEmbeddingService.supportedLanguages()
        return languages.isEmpty
            ? .unavailable(String(localized: "No system sentence embeddings installed"))
            : .available
    }
}
