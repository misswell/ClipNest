import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var showsStatusBanner = false
    @Published var pendingDraft: GeneratedNoteDraft?
    @Published var errorMessage: String?
    @Published private(set) var lastSavedURL: URL?

    private let store: VaultStore
    private let clipboardService: ClipboardProviding
    private let noteGenerator: NoteGenerating?
    private let defaults = UserDefaults.standard

    private var didStart = false
    private var isRunning = false
    private var lastSnapshot: ClipboardSnapshot?
    private var bannerTask: Task<Void, Never>?

    init(store: VaultStore) {
        self.store = store
        self.clipboardService = ClipboardService()
        self.noteGenerator = nil
    }

    init(store: VaultStore, clipboardService: ClipboardProviding) {
        self.store = store
        self.clipboardService = clipboardService
        self.noteGenerator = nil
    }

    init(store: VaultStore,
         clipboardService: ClipboardProviding,
         noteGenerator: NoteGenerating) {
        self.store = store
        self.clipboardService = clipboardService
        self.noteGenerator = noteGenerator
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
        let configuration = AIConfigurationStore.load()
        state = .generating
        statusMessage = String(localized: "Generating note…")
        if let noteGenerator {
            return try await noteGenerator.generate(
                from: snapshot.content,
                existingCategories: categories,
                preferredLanguage: configuration.preferredLanguage
            )
        }
        return try await NoteGenerationService(configuration: configuration)
            .generate(from: snapshot.content,
                      existingCategories: categories,
                      preferredLanguage: configuration.preferredLanguage)
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

#if os(iOS)
    /// Records a photo picked through the zero-permission system picker (PHPicker):
    /// recognize its text and organize it into a note.
    func capturePhoto(_ image: UIImage) async {
        guard !isRunning else { return }
        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        await finishPhotoCapture(image)
    }

    private func finishPhotoCapture(_ image: UIImage) async {
        state = .analyzing
        statusMessage = String(localized: "Recognizing text in photo…")
        let ocrText = (try? await Task.detached(priority: .utility) {
            try PhotoCaptureService.recognizeText(in: image)
        }.value) ?? ""

        // When a separate image model is configured, send the photo to it directly
        // (vision). Otherwise the OCR text flows into the text model pipeline.
        let imageConfig = AIConfigurationStore.loadImageConfiguration()
        if imageConfig.usesSeparateEndpoint {
            let imageAI = AIConfiguration(baseURL: imageConfig.baseURL,
                                          apiKey: imageConfig.apiKey,
                                          model: imageConfig.model,
                                          preferredLanguage: AIConfigurationStore.load().preferredLanguage)
            if imageAI.isValid, let jpegData = image.jpegData(compressionQuality: 0.6) {
                state = .generating
                statusMessage = String(localized: "Reading photo with image model…")
                do {
                    let provider = OpenAICompatibleProvider(configuration: imageAI)
                    let generated = try await provider.generateVisionNote(
                        imageData: jpegData,
                        ocrText: ocrText,
                        existingCategories: store.topLevelCategories(),
                        preferredLanguage: AIConfigurationStore.load().preferredLanguage)
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
#endif

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
