import Foundation

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var statusMessage = ""
    /// Live detail for the status banner while a capture is being organized. `nil` whenever
    /// nothing is running, so the banner can fall back to its plain spinner.
    @Published private(set) var generationProgress: NoteGenerationProgress?
    @Published private(set) var showsStatusBanner = false
    @Published var pendingDraft: GeneratedNoteDraft?
    @Published var errorMessage: String?
    @Published private(set) var lastSavedURL: URL?

    private let store: VaultStore
    private let clipboardService: ClipboardProviding
    private let noteGenerator: NoteGenerating?
    private let ocrService: OCRRecognizing
    private let defaults: UserDefaults
    /// What "warming the model" actually does. Injected so the coordinator can be tested without
    /// the weights or the on-device runtime, and so §17 keeps holding: this layer knows only that
    /// *something* should be warmed, never what that something is. The comment deliberately avoids
    /// naming either the runtime or the model, so a mechanical search for those names across this
    /// whole directory still comes back empty and the layering stays auditable by grep.
    private let preloadLocalModel: @MainActor () -> Void

    private var didStart = false
    private var isRunning = false
    private var lastSnapshot: ClipboardSnapshot?
    private var bannerTask: Task<Void, Never>?

    convenience init(store: VaultStore) {
        self.init(store: store, clipboardService: ClipboardService(), noteGenerator: nil)
    }

    convenience init(store: VaultStore, clipboardService: ClipboardProviding) {
        self.init(store: store, clipboardService: clipboardService, noteGenerator: nil)
    }

    init(store: VaultStore,
         clipboardService: ClipboardProviding,
         noteGenerator: NoteGenerating?,
         ocrService: OCRRecognizing = VisionOCRService(),
         defaults: UserDefaults = .standard,
         preloadLocalModel: @escaping @MainActor () -> Void = {
             LocalModelManager.shared.preloadIfReady()
         }) {
        self.store = store
        self.clipboardService = clipboardService
        self.noteGenerator = noteGenerator
        self.ocrService = ocrService
        self.defaults = defaults
        self.preloadLocalModel = preloadLocalModel
    }

    deinit {
        bannerTask?.cancel()
    }

    var isProcessing: Bool { state.isProcessing }

    /// Called once when the root scene appears. A second call is harmless and still checks
    /// the pasteboard, which covers the case where the vault restore finished first.
    func start() async {
        if !didStart {
            didStart = true
            store.restoreVaultIfNeeded()
        }
        await processClipboardIfNeeded()
        await retryPendingCaptures()
    }

    /// Captures that were interrupted (app quit mid-request) are re-run here, oldest
    /// first. A job that fails again stays queued for the next launch.
    func retryPendingCaptures() async {
        let pending = PendingCaptureStore.load()
        guard !pending.isEmpty, !isRunning else { return }

        showsStatusBanner = true
        state = .detecting
        statusMessage = String(localized: "Retrying unfinished captures…")

        for job in pending {
            guard !isRunning else { break }
            statusMessage = String(localized: "Retrying unfinished capture…")
            await captureText(job.rawText)
            if state == .failed { break }   // surface the error once; job stays queued
        }
    }

    /// Called whenever the scene returns to the foreground. Clipboard access stays inside
    /// this active-scene path, satisfying iOS pasteboard privacy rules.
    func sceneDidBecomeActive() async {
        if !didStart {
            await start()
        } else {
            await processClipboardIfNeeded()
        }
    }

    func reprocessClipboard() async {
        pendingDraft = nil
        errorMessage = nil
        await processClipboardIfNeeded(force: true)
    }

    func retry() async {
        pendingDraft = nil
        errorMessage = nil
        await processClipboardIfNeeded(force: true)
    }

    func saveDraft(_ draft: GeneratedNoteDraft) async {
        guard !isRunning else { return }
        guard let originalContent = ClipboardContent(text: draft.originalText) else {
            errorMessage = String(localized: "The original clipboard content is empty and cannot be saved.")
            state = .failed
            return
        }

        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        state = .saving
        statusMessage = String(localized: "Saving note…")

        do {
            var note = draft.note
            note.category = FileNameSanitizer.directoryName(from: draft.category,
                                                             fallback: ClassificationService.inbox)
            let url = try await store.saveGeneratedNote(note: note,
                                                         originalContent: originalContent)
            markProcessed(draft.clipboardHash)
            lastSavedURL = url
            pendingDraft = nil
            state = .completed
            statusMessage = String(localized: "Saved to \(note.category)")
            scheduleBannerDismissal()
        } catch {
            state = .failed
            statusMessage = String(localized: "Capture failed")
            errorMessage = message(for: error)
        }
        isRunning = false
    }

    func cancelPendingDraft() {
        if let hash = pendingDraft?.clipboardHash {
            PendingCaptureStore.remove(hash: hash)
        }
        pendingDraft = nil
        state = .idle
        statusMessage = String(localized: "Save canceled. The clipboard content is untouched.")
        showsStatusBanner = true
        scheduleBannerDismissal()
    }

    /// Hides the transient status banner without changing or canceling the work it reports.
    func dismissStatusBanner() {
        bannerTask?.cancel()
        showsStatusBanner = false
    }

    func saveRawClipboard() async {
        guard !isRunning else { return }
        guard let snapshot = lastSnapshot ?? clipboardService.readCurrent() else {
            errorMessage = String(localized: "There is no saveable text on the clipboard.")
            return
        }

        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        state = .saving
        statusMessage = String(localized: "Saving raw content…")
        do {
            let url = try await store.saveRawClipboard(snapshot.content)
            markProcessed(snapshot.hash)
            lastSavedURL = url
            pendingDraft = nil
            state = .completed
            statusMessage = String(localized: "Raw content saved to Inbox")
            scheduleBannerDismissal()
        } catch {
            state = .failed
            statusMessage = String(localized: "Save failed")
            errorMessage = message(for: error)
        }
        isRunning = false
    }

    func dismissError() {
        errorMessage = nil
        if state == .failed {
            state = .idle
            statusMessage = ""
            showsStatusBanner = false
        }
    }

    private func processClipboardIfNeeded(force: Bool = false) async {
        guard !isRunning else { return }
        guard force || automaticDetectionEnabled else {
            state = .idle
            statusMessage = String(localized: "Automatic clipboard detection is off")
            showsStatusBanner = false
            return
        }

        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        state = .detecting
        statusMessage = String(localized: "Detecting clipboard…")

        if !force {
            let currentChangeCount = clipboardService.changeCount()
            let recordedChangeCount = defaults.object(forKey: ClipNestSettings.lastClipboardChangeCount) as? Int
            if let recordedChangeCount, recordedChangeCount == currentChangeCount {
                isRunning = false
                state = .idle
                statusMessage = String(localized: "Clipboard unchanged")
                showsStatusBanner = false
                return
            }
        }

        guard let snapshot = clipboardService.readCurrent() else {
            isRunning = false
            state = .idle
            statusMessage = String(localized: "No processable text on the clipboard")
            // A forced run comes from an explicit user action, so it always reports back;
            // the automatic pass stays silent to avoid banners on every foreground return.
            showsStatusBanner = force
            if force { scheduleBannerDismissal() }
            return
        }
        lastSnapshot = snapshot
        record(snapshot)

        let lastProcessed = defaults.string(forKey: ClipNestSettings.lastClipboardHash)
        let lastAttempted = defaults.string(forKey: ClipNestSettings.lastAttemptedClipboardHash)
        if !force && (snapshot.hash == lastProcessed || snapshot.hash == lastAttempted) {
            isRunning = false
            state = .idle
            statusMessage = String(localized: "Clipboard content already processed")
            showsStatusBanner = false
            return
        }

        if !force && !automaticGenerationEnabled {
            isRunning = false
            state = .idle
            statusMessage = String(localized: "New clipboard content detected — organize it manually from Settings")
            showsStatusBanner = true
            scheduleBannerDismissal()
            return
        }

        await generateAndSave(snapshot)
    }

    /// The shared note-organization pipeline behind clipboard and photo captures:
    /// queue → AI generation → classification → save (or stage for confirmation).
    /// A failed request stays in the queue and is retried on the next launch.
    private func generateAndSave(_ snapshot: ClipboardSnapshot) async {
        // Record an attempt before making a network request. A foreground/background cycle
        // during a failing request must not start another request for the same hash.
        defaults.set(snapshot.hash, forKey: ClipNestSettings.lastAttemptedClipboardHash)
        PendingCaptureStore.add(hash: snapshot.hash,
                                rawText: snapshot.content.rawText,
                                source: "capture")

        do {
            let generated = try await generateNote(for: snapshot)
            try await classifyAndSave(generated, snapshot: snapshot)
        } catch is CancellationError {
            state = .idle
            statusMessage = ""
            showsStatusBanner = false
            isRunning = false
        } catch {
            state = .failed
            statusMessage = String(localized: "Capture failed")
            showsStatusBanner = false
            errorMessage = message(for: error)
            // Keep the job queued — it is retried automatically on the next launch.
            isRunning = false
        }
    }

    private func generateNote(for snapshot: ClipboardSnapshot) async throws -> GeneratedNote {
        state = .analyzing
        statusMessage = String(localized: "Analyzing content…")
        let categories = store.topLevelCategories()
        let configuration = GenerationConfiguration.load()
        state = .generating
        statusMessage = generationStatusMessage(for: configuration.mode)
        generationProgress = nil

        let generator: any NoteGenerating = noteGenerator
            // The coordinator does not know whether this ends up in the downloaded local
            // model, Local Lite or the OpenAI-compatible provider — the router decides.
            ?? NoteGenerationRouter(configuration: configuration,
                                    categoryProfiles: store.categoryProfiles())

        defer { generationProgress = nil }
        return try await generate(using: generator,
                                  from: snapshot.content,
                                  existingCategories: categories,
                                  preferredLanguage: configuration.text.preferredLanguage)
    }

    /// Runs the generator, forwarding progress to the banner when it can report any.
    ///
    /// The progress callback arrives on a background context, so it is hopped to the main actor
    /// before touching published state.
    private func generate(using generator: any NoteGenerating,
                          from content: ClipboardContent,
                          existingCategories: [String],
                          preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        guard let reporting = generator as? ProgressReportingNoteGenerating else {
            return try await generator.generate(from: content,
                                                existingCategories: existingCategories,
                                                preferredLanguage: preferredLanguage)
        }
        return try await reporting.generate(
            from: content,
            existingCategories: existingCategories,
            preferredLanguage: preferredLanguage,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in self?.applyGenerationProgress(progress) }
            }
        )
    }

    /// Warms the on-device model so the next capture does not pay the load.
    ///
    /// Called when the app becomes active and when a capture is requested, never on a cold
    /// launch with no signal from the user. Gated by a setting because it keeps ~350 MB
    /// resident for as long as the app is in the foreground (§26); the existing unload-on-
    /// pressure and unload-on-background behaviour is what bounds that.
    func preloadLocalModelIfEnabled() {
        preloadLocalModelIfEnabled(mode: GenerationConfiguration.load().mode)
    }

    /// - Parameter mode: injected rather than read from `GenerationConfiguration`, so the rule can
    ///   be exercised without writing to global user defaults (which would leak between tests).
    func preloadLocalModelIfEnabled(mode: AIProcessingMode) {
        // Never warm anything for an online configuration: there is no local model to warm, and
        // touching one would be a step towards the network in a mode that must not need it (§11).
        guard mode == .local else { return }
        guard defaults.object(forKey: ClipNestSettings.localModelPreload) as? Bool ?? true else {
            return
        }
        preloadLocalModel()
    }

    /// Maps one generation phase onto what the banner shows.
    ///
    /// Internal rather than private so the phase → message mapping can be asserted directly: it
    /// is the whole of what the user sees while a note is being organized, and a wrong string here
    /// is the "stuck spinner" complaint in a different costume.
    func applyGenerationProgress(_ progress: NoteGenerationProgress) {
        generationProgress = progress
        switch progress {
        case .preparingEngine:
            statusMessage = String(localized: "Preparing the on-device model…")
        case .generating(let preview):
            statusMessage = preview.isEmpty
                ? generationStatusMessage(for: .local)
                : String(localized: "Writing the note…")
        case .finishing:
            statusMessage = String(localized: "Saving note…")
        }
    }

    private func generationStatusMessage(for mode: AIProcessingMode) -> String {
        switch mode {
        case .local:
            return LocalModelManager.shared.state.isReady
                ? String(localized: "Generating note on device…")
                : String(localized: "Organizing on device…")
        case .online:
            return String(localized: "Generating note…")
        }
    }

    private func classifyAndSave(_ generated: GeneratedNote, snapshot: ClipboardSnapshot) async throws {
        state = .classifying
        statusMessage = String(localized: "Classifying…")
        let finalCategories = store.topLevelCategories()
        let category = ClassificationService().classify(
            note: generated,
            existingCategories: finalCategories,
            configuration: .load()
        )
        var note = generated
        note.category = category

        let mode = ClipboardProcessingMode(
            rawValue: defaults.string(forKey: ClipNestSettings.processingMode)
                ?? ClipboardProcessingMode.automatic.rawValue
        ) ?? .automatic
        if mode == .confirmBeforeSave {
            pendingDraft = GeneratedNoteDraft(note: note, snapshot: snapshot)
            isRunning = false
            state = .completed
            statusMessage = String(localized: "Note generated — confirm to save")
            return
        }

        state = .saving
        statusMessage = String(localized: "Saving to \(category)…")
        let url = try await store.saveGeneratedNote(note: note,
                                                     originalContent: snapshot.content)
        markProcessed(snapshot.hash)
        lastSavedURL = url
        state = .completed
        statusMessage = String(localized: "Saved to \(category)")
        scheduleBannerDismissal()
        isRunning = false
    }

    // MARK: - Photo capture

    /// Captures raw text from any source (e.g. OCR output) and runs it through the
    /// same organization pipeline as clipboard content.
    func captureText(_ rawText: String) async {
        guard !isRunning else { return }
        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        guard let content = ClipboardContent(text: rawText) else {
            isRunning = false
            state = .idle
            statusMessage = String(localized: "No readable text was recognized")
            scheduleBannerDismissal()
            return
        }
        state = .analyzing
        statusMessage = String(localized: "Analyzing content…")
        let snapshot = ClipboardSnapshot(
            content: content,
            changeCount: defaults.integer(forKey: ClipNestSettings.lastClipboardChangeCount),
            hash: ClipboardContent.hash(for: content.rawText))
        lastSnapshot = snapshot
        await generateAndSave(snapshot)
    }

    /// Records a photo: recognize its text on device and organize it into a note.
    /// Cross-platform — the Mac path uses the same Vision code as the phone.
    func capturePhoto(_ image: PlatformImage) async {
        guard !isRunning else { return }
        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        await finishPhotoCapture(image)
    }

    private func finishPhotoCapture(_ image: PlatformImage) async {
        state = .analyzing
        statusMessage = String(localized: "Recognizing text in photo…")
        let ocrResult = await recognizeText(in: image)
        let ocrText = OCRPostProcessor.process(ocrResult.text)

        // A separate image model is only ever considered when the mode allows a network
        // request at all. In local mode the photo is read by Vision and nothing else.
        let configuration = GenerationConfiguration.load()
        if shouldUseImageModel(configuration) {
            let imageAI = AIConfiguration(baseURL: configuration.image.baseURL,
                                          apiKey: configuration.image.apiKey,
                                          model: configuration.image.model,
                                          preferredLanguage: configuration.text.preferredLanguage)
            if imageAI.isValid, let jpegData = image.jpegDataForUpload(compressionQuality: 0.6) {
                state = .generating
                statusMessage = String(localized: "Reading photo with image model…")
                do {
                    let provider = OpenAICompatibleProvider(configuration: imageAI)
                    let generated = try await provider.generateVisionNote(
                        imageData: jpegData,
                        ocrText: ocrText,
                        existingCategories: store.topLevelCategories(),
                        preferredLanguage: configuration.text.preferredLanguage)
                    let anchorText = ocrText.isEmpty ? String(localized: "(photo)") : ocrText
                    guard let anchorContent = ClipboardContent(text: anchorText) else {
                        isRunning = false
                        state = .idle
                        return
                    }
                    let snapshot = ClipboardSnapshot(
                        content: anchorContent,
                        changeCount: defaults.integer(forKey: ClipNestSettings.lastClipboardChangeCount),
                        hash: ClipboardContent.hash(for: ocrText.isEmpty ? "photo:\(Date().timeIntervalSince1970)" : ocrText))
                    lastSnapshot = snapshot
                    try await classifyAndSave(generated, snapshot: snapshot)
                    return
                } catch {
                    // Fall through to the OCR + text-model pipeline.
                    statusMessage = String(localized: "Image model failed — falling back to text model…")
                }
            }
        }

        guard let content = ClipboardContent(text: ocrText) else {
            isRunning = false
            state = .idle
            statusMessage = String(localized: "No readable text was found in the photo")
            scheduleBannerDismissal()
            return
        }
        statusMessage = String(localized: "Text recognized — organizing…")
        let snapshot = ClipboardSnapshot(
            content: content,
            changeCount: defaults.integer(forKey: ClipNestSettings.lastClipboardChangeCount),
            hash: ClipboardContent.hash(for: content.rawText))
        lastSnapshot = snapshot
        await generateAndSave(snapshot)
    }

    /// Vision OCR only. Failures are reported as an empty result rather than thrown, because
    /// "no text in this photo" is a normal outcome, not an error.
    private func recognizeText(in image: PlatformImage) async -> OCRResult {
        guard let cgImage = image.ocrCGImage else { return .empty }
        do {
            return try await ocrService.recognizeText(cgImage: cgImage, languages: [])
        } catch {
            return .empty
        }
    }

    /// Whether the vision endpoint may be used for this capture. Local mode is a hard no:
    /// the photo is recognized with on-device Vision OCR and nothing else (China plan §9).
    private func shouldUseImageModel(_ configuration: GenerationConfiguration) -> Bool {
        guard configuration.image.usesSeparateEndpoint else { return false }
        switch configuration.mode {
        case .local:
            return false
        case .online:
            return true
        }
    }

    private func record(_ snapshot: ClipboardSnapshot) {
        defaults.set(snapshot.hash, forKey: ClipNestSettings.lastSeenClipboardHash)
        defaults.set(snapshot.changeCount, forKey: ClipNestSettings.lastClipboardChangeCount)
    }

    private func markProcessed(_ hash: String) {
        defaults.set(hash, forKey: ClipNestSettings.lastClipboardHash)
        defaults.set(hash, forKey: ClipNestSettings.lastAttemptedClipboardHash)
        PendingCaptureStore.remove(hash: hash)
    }

    private var automaticDetectionEnabled: Bool {
        defaults.object(forKey: ClipNestSettings.autoDetectClipboard) as? Bool ?? true
    }

    private var automaticGenerationEnabled: Bool {
        defaults.object(forKey: ClipNestSettings.autoGenerateNote) as? Bool ?? true
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func scheduleBannerDismissal() {
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self,
                  self.state == .completed || self.state == .idle
            else { return }
            self.state = .idle
            self.statusMessage = ""
            self.showsStatusBanner = false
        }
    }

}
