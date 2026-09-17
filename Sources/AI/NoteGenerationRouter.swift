import Foundation

/// Picks the provider for a capture (China plan §16, §17).
///
/// The coordinator only ever calls `generate(...)`. This type is the single place that knows
/// the local model, Local Lite and the OpenAI-compatible provider exist — and the single place
/// that enforces the privacy boundary. In `.local`, `onlineProviderFactory` is not reachable
/// from any code path, and no failure below can change that (spec §11): a model that is
/// missing, corrupt, out of memory or simply wrong degrades to Local Lite, never to the network.
struct NoteGenerationRouter: ProgressReportingNoteGenerating {
    /// Builds the network-capable provider. Tests inject a counting or failing implementation
    /// here to prove `.local` never reaches the network.
    typealias OnlineProviderFactory = (AIConfiguration) -> any NoteGenerating

    let mode: AIProcessingMode
    let onlineConfiguration: AIConfiguration
    /// Category fingerprints used by the local classifier. Empty falls back to bare names.
    var categoryProfiles: [CategoryProfile]

    /// The downloaded local model, when one is installed. `nil` is the normal state for a
    /// fresh install and simply means Local Lite runs instead.
    var localModelProvider: (any NoteGenerating)?
    /// Always-available local engine. Needs no download, no API key and no network.
    var localLiteProviderFactory: ([CategoryProfile]) -> any NoteGenerating
    /// Network provider.
    var onlineProviderFactory: OnlineProviderFactory

    init(mode: AIProcessingMode,
         onlineConfiguration: AIConfiguration,
         categoryProfiles: [CategoryProfile] = [],
         localModelProvider: (any NoteGenerating)? = nil,
         localLiteProviderFactory: @escaping ([CategoryProfile]) -> any NoteGenerating = {
             LocalLiteNoteProvider(profiles: $0)
         },
         onlineProviderFactory: @escaping OnlineProviderFactory = {
             NoteGenerationService(configuration: $0)
         }) {
        self.mode = mode
        self.onlineConfiguration = onlineConfiguration
        self.categoryProfiles = categoryProfiles
        self.localModelProvider = localModelProvider
        self.localLiteProviderFactory = localLiteProviderFactory
        self.onlineProviderFactory = onlineProviderFactory
    }

    /// Convenience initialiser from persisted settings, resolving the installed model.
    ///
    /// `@MainActor` because that resolution consults `LocalModelManager`; the resulting router
    /// is an ordinary value and can then be used from anywhere.
    @MainActor
    init(configuration: GenerationConfiguration, categoryProfiles: [CategoryProfile] = []) {
        self.init(mode: configuration.mode,
                  onlineConfiguration: configuration.text,
                  categoryProfiles: categoryProfiles,
                  localModelProvider: LocalModelManager.shared.makeProviderIfReady(
                      profiles: categoryProfiles))
    }

    var hasValidOnlineConfiguration: Bool { onlineConfiguration.isValid }

    /// Which engine will actually run for a local capture. Shown in the capture status line.
    var localEngineName: String {
        localModelProvider != nil
            ? LocalModelDescriptor.qwen3.displayName
            : LocalLiteNoteProvider.engineName
    }

    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        try await generate(from: content,
                           existingCategories: existingCategories,
                           preferredLanguage: preferredLanguage,
                           onProgress: nil)
    }

    /// Progress is forwarded only on the local path, and only because the local provider can
    /// report it. The online path keeps its single-call shape: an API that streams would need
    /// its own implementation, and reporting nothing is better than reporting something false.
    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage,
                  onProgress: (@Sendable (NoteGenerationProgress) -> Void)?) async throws -> GeneratedNote {
        switch mode {
        case .local:
            return try await generateLocally(from: content,
                                             existingCategories: existingCategories,
                                             preferredLanguage: preferredLanguage,
                                             onProgress: onProgress)
        case .online:
            return try await generateOnline(from: content,
                                            existingCategories: existingCategories,
                                            preferredLanguage: preferredLanguage)
        }
    }

    // MARK: - Local (never touches the network)

    /// Downloaded model first, Local Lite second. There is deliberately no third step, and no
    /// branch in here has a reference to `onlineProviderFactory`.
    private func generateLocally(from content: ClipboardContent,
                                 existingCategories: [String],
                                 preferredLanguage: PreferredLanguage,
                                 onProgress: (@Sendable (NoteGenerationProgress) -> Void)? = nil) async throws -> GeneratedNote {
        if let localModelProvider {
            do {
                if let reporting = localModelProvider as? ProgressReportingNoteGenerating {
                    return try await reporting.generate(from: content,
                                                        existingCategories: existingCategories,
                                                        preferredLanguage: preferredLanguage,
                                                        onProgress: onProgress)
                }
                return try await localModelProvider.generate(from: content,
                                                             existingCategories: existingCategories,
                                                             preferredLanguage: preferredLanguage)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Missing, corrupt, out of memory, unreadable JSON — all of it stays on the
                // device. This is the privacy boundary (spec §11), so the degrade is
                // unconditional rather than filtered by error type.
                return try await generateLocalLite(from: content,
                                                   existingCategories: existingCategories,
                                                   preferredLanguage: preferredLanguage)
            }
        }
        return try await generateLocalLite(from: content,
                                           existingCategories: existingCategories,
                                           preferredLanguage: preferredLanguage)
    }

    private func generateLocalLite(from content: ClipboardContent,
                                   existingCategories: [String],
                                   preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        let lite = localLiteProviderFactory(categoryProfiles)
        return try await lite.generate(from: content,
                                       existingCategories: existingCategories,
                                       preferredLanguage: preferredLanguage)
    }

    // MARK: - Online (existing behaviour, unchanged)

    private func generateOnline(from content: ClipboardContent,
                                existingCategories: [String],
                                preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        let provider = onlineProviderFactory(onlineConfiguration)
        return try await provider.generate(from: content,
                                           existingCategories: existingCategories,
                                           preferredLanguage: preferredLanguage)
    }
}
