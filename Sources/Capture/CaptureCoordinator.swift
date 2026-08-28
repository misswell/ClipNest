import Foundation

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
            errorMessage = "原始剪贴板内容为空，无法保存。"
            state = .failed
            return
        }

        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        state = .saving
        statusMessage = "正在保存笔记…"

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
            statusMessage = "已保存到「\(note.category)」"
            scheduleBannerDismissal()
        } catch {
            state = .failed
            statusMessage = "整理失败"
            errorMessage = message(for: error)
        }
        isRunning = false
    }

    func cancelPendingDraft() {
        pendingDraft = nil
        state = .idle
        statusMessage = "已取消保存，剪贴板内容仍保留。"
        showsStatusBanner = true
        scheduleBannerDismissal()
    }

    func saveRawClipboard() async {
        guard !isRunning else { return }
        guard let snapshot = lastSnapshot ?? clipboardService.readCurrent() else {
            errorMessage = "当前剪贴板没有可保存的文本。"
            return
        }

        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        state = .saving
        statusMessage = "正在保存原始内容…"
        do {
            let url = try await store.saveRawClipboard(snapshot.content)
            markProcessed(snapshot.hash)
            lastSavedURL = url
            pendingDraft = nil
            state = .completed
            statusMessage = "原始内容已保存到「Inbox」"
            scheduleBannerDismissal()
        } catch {
            state = .failed
            statusMessage = "保存失败"
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
            statusMessage = "自动读取剪贴板已关闭"
            showsStatusBanner = false
            return
        }

        bannerTask?.cancel()
        isRunning = true
        errorMessage = nil
        showsStatusBanner = true
        state = .detecting
        statusMessage = "正在检测剪贴板…"

        if !force {
            let currentChangeCount = clipboardService.changeCount()
            let recordedChangeCount = defaults.object(forKey: ClipNestSettings.lastClipboardChangeCount) as? Int
            if let recordedChangeCount, recordedChangeCount == currentChangeCount {
                isRunning = false
                state = .idle
                statusMessage = "剪贴板未发生变化"
                showsStatusBanner = false
                return
            }
        }

        guard let snapshot = clipboardService.readCurrent() else {
            isRunning = false
            state = .idle
            statusMessage = "剪贴板中没有可处理的文本"
            showsStatusBanner = false
            return
        }
        lastSnapshot = snapshot
        record(snapshot)

        let lastProcessed = defaults.string(forKey: ClipNestSettings.lastClipboardHash)
        let lastAttempted = defaults.string(forKey: ClipNestSettings.lastAttemptedClipboardHash)
        if !force && (snapshot.hash == lastProcessed || snapshot.hash == lastAttempted) {
            isRunning = false
            state = .idle
            statusMessage = "剪贴板内容已处理"
            showsStatusBanner = false
            return
        }

        if !force && !automaticGenerationEnabled {
            isRunning = false
            state = .idle
            statusMessage = "检测到新的剪贴板内容，可在设置中手动整理"
            showsStatusBanner = true
            scheduleBannerDismissal()
            return
        }

        // Record an attempt before making a network request. A foreground/background cycle
        // during a failing request must not start another request for the same hash.
        defaults.set(snapshot.hash, forKey: ClipNestSettings.lastAttemptedClipboardHash)

        do {
            state = .analyzing
            statusMessage = "正在分析内容…"
            let categories = store.topLevelCategories()
            let configuration = AIConfigurationStore.load()
            state = .generating
            statusMessage = "正在生成笔记…"
            let generated: GeneratedNote
            if let noteGenerator {
                generated = try await noteGenerator.generate(
                    from: snapshot.content,
                    existingCategories: categories,
                    preferredLanguage: configuration.preferredLanguage
                )
            } else {
                generated = try await NoteGenerationService(configuration: configuration)
                    .generate(from: snapshot.content,
                              existingCategories: categories,
                              preferredLanguage: configuration.preferredLanguage)
            }

            state = .classifying
            statusMessage = "正在分类…"
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
                statusMessage = "笔记已生成，请确认后保存"
                return
            }

            state = .saving
            statusMessage = "正在保存到「\(category)」…"
            let url = try await store.saveGeneratedNote(note: note,
                                                         originalContent: snapshot.content)
            markProcessed(snapshot.hash)
            lastSavedURL = url
            state = .completed
            statusMessage = "已保存到「\(category)」"
            scheduleBannerDismissal()
        } catch is CancellationError {
            state = .idle
            statusMessage = ""
            showsStatusBanner = false
        } catch {
            state = .failed
            statusMessage = "整理失败"
            showsStatusBanner = false
            errorMessage = message(for: error)
        }
        isRunning = false
    }

    private func record(_ snapshot: ClipboardSnapshot) {
        defaults.set(snapshot.hash, forKey: ClipNestSettings.lastSeenClipboardHash)
        defaults.set(snapshot.changeCount, forKey: ClipNestSettings.lastClipboardChangeCount)
    }

    private func markProcessed(_ hash: String) {
        defaults.set(hash, forKey: ClipNestSettings.lastClipboardHash)
        defaults.set(hash, forKey: ClipNestSettings.lastAttemptedClipboardHash)
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
