import SwiftUI

/// Settings tab — vault management and display preferences.
struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var captureCoordinator: CaptureCoordinator
    @AppStorage("settings.previewDefault") private var previewDefault = false
    @AppStorage("editor.multipleTabs") private var multipleTabs = true

    @AppStorage(ClipNestSettings.autoDetectClipboard) private var autoDetectClipboard = true
    @AppStorage(ClipNestSettings.autoGenerateNote) private var autoGenerateNote = true
    @AppStorage(ClipNestSettings.processingMode) private var processingMode = ClipboardProcessingMode.automatic.rawValue

    /// How notes are organized. Default is local: a fresh install is private and works with
    /// no API key, no account and no network (China plan §8).
    @AppStorage(ClipNestSettings.aiProcessingMode) private var aiProcessingMode = AIProcessingMode.recommended.rawValue
    @AppStorage(ClipNestSettings.localSemanticSearch) private var localSemanticSearch = true
    @AppStorage(ClipNestSettings.localQueryExpansion) private var localQueryExpansion = true
    /// The CDN serving `model-manifest.json` (China plan §4).
    @AppStorage(ClipNestSettings.localModelManifestURL) private var modelManifestURL = ""
    @AppStorage(ClipNestSettings.localModelPreload) private var localModelPreload = true
    @AppStorage(ClipNestSettings.localBodyStyle) private var localBodyStyle = LocalBodyStyle.default.rawValue
    @EnvironmentObject private var search: LocalSearchController
    @StateObject private var modelManager = LocalModelManager.shared
    @State private var capabilities: LocalAICapabilities?

    @State private var aiBaseURL: String
    @State private var aiModel: String
    @State private var preferredLanguage: String
    @State private var apiKey: String
    @State private var aiSettingsSaved = false
    @State private var imageUsesSeparateEndpoint: Bool
    @State private var imageBaseURL: String
    @State private var imageModel: String
    @State private var imageAPIKey: String

    @AppStorage(ClipNestSettings.autoClassify) private var autoClassify = true
    @AppStorage(ClipNestSettings.allowNewCategories) private var allowNewCategories = false
    @AppStorage(ClipNestSettings.defaultCategory) private var defaultCategory = ClassificationService.inbox

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showSwitchVaultConfirmation = false
    @State private var pendingVaultURL: URL?
    @State private var showCloseVaultConfirmation = false
    @State private var showTrash = false
    @State private var iconPreference = AppIconPreference.system

    /// Obsidian shortcut state.
    @State private var showObsidianSheet = false
    @State private var obsidianVaults: [ObsidianVault] = []
    @State private var isScanningObsidian = false
    /// Set by the sheet, run once it has finished dismissing — the folder picker and the
    /// switch confirmation both have to come up *after* the sheet is gone.
    @State private var pendingObsidianAction: ObsidianAction?

    init() {
        let configuration = AIConfigurationStore.load()
        _aiBaseURL = State(initialValue: configuration.baseURL)
        _aiModel = State(initialValue: configuration.model)
        _preferredLanguage = State(initialValue: configuration.preferredLanguage.rawValue)
        _apiKey = State(initialValue: configuration.apiKey)
        let imageConfiguration = AIConfigurationStore.loadImageConfiguration()
        _imageUsesSeparateEndpoint = State(initialValue: imageConfiguration.usesSeparateEndpoint)
        _imageBaseURL = State(initialValue: imageConfiguration.baseURL)
        _imageModel = State(initialValue: imageConfiguration.model)
        _imageAPIKey = State(initialValue: imageConfiguration.apiKey)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                Text("Settings").font(.largeTitle.bold())

                // Vault
                sectionCard("VAULT") {
                    HStack {
                        Label("Current Vault", systemImage: "folder.fill")
                        Spacer()
                        Text(store.vaultName).foregroundStyle(Theme.mutedInk)
                        Button {
                            renameText = store.vaultName
                            showRename = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename this vault")
                        .disabled(store.rootURL == nil)
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Button {
                        pendingVaultURL = nil
                        showSwitchVaultConfirmation = true
                    } label: {
                        Label("Open Another Folder…", systemImage: "folder.badge.plus")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Button {
                        beginObsidianScan()
                    } label: {
                        HStack(spacing: 12) {
                            Label("Obsidian Vault…", systemImage: "square.stack.3d.up")
                            Spacer(minLength: 8)
                            if isScanningObsidian {
                                ProgressView().controlSize(.small)
                            } else if !obsidianVaults.isEmpty {
                                Text("\(obsidianVaults.count)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.mutedInk)
                            }
                        }
                    }
                    .disabled(isScanningObsidian)
                    .padding(.vertical, AppMetrics.rowVertical)
                    Text("Jump straight to the vaults Obsidian keeps in its default folders (iCloud Drive ▸ Obsidian).")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, AppMetrics.rowVertical)
                    rowDivider
                    Button {
                        showTrash = true
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Button(role: .destructive) {
                        showCloseVaultConfirmation = true
                    } label: {
                        Label("Close Vault", systemImage: "xmark.circle")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                }

                // Recent vaults — one-click switching, Obsidian-style.
                let others = store.recentVaults.filter { $0.standardizedFileURL != store.rootURL?.standardizedFileURL }
                if !others.isEmpty {
                    sectionCard("RECENT VAULTS") {
                        ForEach(Array(others.enumerated()), id: \.element) { index, url in
                            if index > 0 { rowDivider }
                            HStack {
                                Button {
                                    pendingVaultURL = url
                                    showSwitchVaultConfirmation = true
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label(store.displayName(for: url), systemImage: "folder")
                                        Text(url.path)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.mutedInk)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button {
                                    store.removeRecent(url)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.mutedInk)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from recent list")
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }

                sectionCard("CLIPBOARD") {
                    Toggle(isOn: $autoDetectClipboard) {
                        Label("Auto-Detect Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Toggle(isOn: $autoGenerateNote) {
                        Label("Auto-Generate Notes", systemImage: "sparkles")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Picker("Processing Mode", selection: $processingMode) {
                        ForEach(ClipboardProcessingMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    Text(ClipboardProcessingMode(rawValue: processingMode)?.description ?? "")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, AppMetrics.rowVertical)
                    rowDivider
                    Button {
                        Task { await captureCoordinator.reprocessClipboard() }
                    } label: {
                        Label("Reprocess Current Clipboard", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                }

                sectionCard("AI PROCESSING") {
                    Text("How notes are organized")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.top, AppMetrics.rowVertical)
                    ForEach(AIProcessingMode.allCases) { mode in
                        processingModeRow(mode)
                    }
                    Text(processingModeDescription)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, AppMetrics.rowVertical)
                }

                if isLocalOnly {
                    sectionCard("LOCAL ENHANCEMENT MODEL") {
                        localModelRows
                    }
                    sectionCard("ON-DEVICE CAPABILITIES") {
                        localCapabilityRows
                        Text("Even without the enhancement model, ClipNest still does basic offline organizing and OCR.")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, AppMetrics.rowVertical)
                    }
                }

                sectionCard("ONLINE AI") {
                    if isLocalOnly {
                        Label("On-device mode never sends anything to the internet.",
                              systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.mutedInk)
                            .padding(.vertical, AppMetrics.cardPadding)
                    } else {
                        onlineAISettings
                    }
                }
                .onChange(of: aiBaseURL) { _, _ in aiSettingsSaved = false }
                .onChange(of: aiModel) { _, _ in aiSettingsSaved = false }
                .onChange(of: preferredLanguage) { _, _ in aiSettingsSaved = false }
                .onChange(of: apiKey) { _, _ in aiSettingsSaved = false }
                .onChange(of: imageUsesSeparateEndpoint) { _, _ in aiSettingsSaved = false }
                .onChange(of: imageBaseURL) { _, _ in aiSettingsSaved = false }
                .onChange(of: imageModel) { _, _ in aiSettingsSaved = false }
                .onChange(of: imageAPIKey) { _, _ in aiSettingsSaved = false }

                sectionCard("ON-DEVICE NOTE GENERATION") {
                    Toggle(isOn: $localModelPreload) {
                        Label("Keep the model ready", systemImage: "bolt.fill")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    Text("Loads the weights while you browse, so the first capture is not the slow one. Costs about 350 MB of memory while the app is open; they are still released on memory pressure and when the app goes to the background.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, AppMetrics.rowVertical)
                    rowDivider
                    Picker(selection: $localBodyStyle) {
                        ForEach(LocalBodyStyle.allCases, id: \.rawValue) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    } label: {
                        Label("Note body", systemImage: "doc.plaintext")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    Text((LocalBodyStyle(rawValue: localBodyStyle) ?? .default).explanation)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, AppMetrics.rowVertical)
                    rowDivider
                }

                sectionCard("LOCAL SEARCH") {
                    Toggle(isOn: $localSemanticSearch) {
                        Label("Smart Search", systemImage: "sparkle.magnifyingglass")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    .onChange(of: localSemanticSearch) { _, enabled in
                        search.setSemanticSearchEnabled(enabled)
                    }
                    Text(VaultSearchMode.smart.description)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, AppMetrics.rowVertical)
                    rowDivider
                    Toggle(isOn: $localQueryExpansion) {
                        Label("Expand queries with the local model", systemImage: "text.append")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    Text("Adds the keywords the local model reads out of your question before searching. Needs the enhancement model; search works without it.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, AppMetrics.rowVertical)
                    rowDivider
                    HStack(spacing: 12) {
                        Label(search.isIndexing
                              ? String(localized: "Indexing…")
                              : String(localized: "\(search.indexedChunkCount) indexed passages"),
                              systemImage: "text.magnifyingglass")
                            .font(.callout)
                        Spacer()
                        Button {
                            search.rebuild()
                        } label: {
                            Label("Rebuild Index", systemImage: "arrow.clockwise")
                        }
                        .disabled(search.isIndexing || store.rootURL == nil)
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    if let statistics = search.statistics {
                        Text("Last pass: \(statistics.indexedFiles) notes · \(statistics.skippedFiles) unchanged · \(statistics.removedFiles) removed")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedInk)
                            .padding(.bottom, AppMetrics.rowVertical)
                    }
                }

                sectionCard("CLASSIFICATION") {
                    Toggle(isOn: $autoClassify) {
                        Label("Auto-Classify", systemImage: "folder.badge.gearshape")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Toggle(isOn: $allowNewCategories) {
                        Label("Allow New Categories", systemImage: "folder.badge.plus")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    TextField("Default Category", text: $defaultCategory)
                        .textFieldStyle(.plain)
                        .padding(.vertical, AppMetrics.rowVertical)
                    Text("When auto-classification is off or nothing matches, the default category is used; otherwise content is saved to Inbox.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, AppMetrics.rowVertical)
                }

                // Display
                sectionCard("DISPLAY") {
                    Toggle(isOn: $store.showHiddenFiles) {
                        Label("Show Hidden Files", systemImage: "eye")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    rowDivider
                    Toggle(isOn: $previewDefault) {
                        Label("Open Notes in Preview", systemImage: "doc.text.image")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    #if os(macOS)
                    rowDivider
                    Toggle(isOn: $multipleTabs) {
                        Label("Show Multiple Editor Tabs", systemImage: "rectangle.split.3x1")
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    #endif
                }

                // App icon — follow the system light/dark appearance or pin one manually.
                sectionCard("APP ICON") {
                    Picker("App Icon", selection: $iconPreference) {
                        ForEach(AppIconPreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .padding(.vertical, AppMetrics.rowVertical)
                    Text("Follow the system light/dark appearance, or pin an icon regardless of it. iOS asks for confirmation when the icon changes.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, AppMetrics.rowVertical)
                }
            }
            .padding(.horizontal, AppMetrics.screenHorizontal)
            .padding(.top, AppMetrics.screenTop)
            .padding(.bottom, AppMetrics.sectionSpacing)
            .frame(maxWidth: AppMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showObsidianSheet, onDismiss: runPendingObsidianAction) {
            ObsidianVaultSheet(
                vaults: obsidianVaults,
                currentVaultURL: store.rootURL,
                onSwitch: { url in
                    pendingObsidianAction = .switchTo(url)
                    showObsidianSheet = false
                },
                onBrowse: {
                    pendingObsidianAction = .browse
                    showObsidianSheet = false
                }
            )
        }
        .bottomTabBarExclusion()
        .background(Theme.background)
        .sheet(isPresented: $showTrash) {
            TrashView()
                .environmentObject(store)
        }
        .alert("Switch Vault?", isPresented: $showSwitchVaultConfirmation) {
            Button("Choose Folder") {
                if let pendingVaultURL {
                    store.openVault(at: pendingVaultURL)
                    self.pendingVaultURL = nil
                } else {
                    store.requestOpenVault()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingVaultURL = nil
            }
        } message: {
            Text("After switching, ClipNest stops using the current vault. Files on disk are not deleted.")
        }
        .alert("Close Vault?", isPresented: $showCloseVaultConfirmation) {
            Button("Close Vault", role: .destructive) {
                store.closeVault()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Closing only detaches the vault from ClipNest. Files on disk are not deleted.")
        }
        .onChange(of: autoDetectClipboard) { _, enabled in
            guard enabled else { return }
            Task { await captureCoordinator.sceneDidBecomeActive() }
        }
        .onAppear {
            iconPreference = AppIconManager.current
            capabilities = LocalAICapabilities.current()
            modelManager.manifestURL = LocalModelManager.configuredManifestURL()
            modelManager.refresh()
        }
        .onChange(of: iconPreference) { _, preference in
            AppIconManager.set(preference)
        }
        // Bridge the importer used elsewhere — settings just toggles the request flag.
    }

    // MARK: - AI processing

    /// Local-only mode hides every online field, so the privacy promise is visible in the UI
    /// rather than only documented (spec §27).
    private var isLocalOnly: Bool {
        AIProcessingMode(rawValue: aiProcessingMode) == .local
    }

    private var processingModeDescription: String {
        (AIProcessingMode(rawValue: aiProcessingMode) ?? .recommended).description
    }

    private func processingModeRow(_ mode: AIProcessingMode) -> some View {
        let selected = AIProcessingMode(rawValue: aiProcessingMode) == mode
        return Button {
            aiProcessingMode = mode.rawValue
            capabilities = LocalAICapabilities.current()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.mutedInk)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .foregroundStyle(Theme.ink)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, AppMetrics.rowVertical)
        }
        .buttonStyle(.plain)
    }

    /// The downloadable enhancement model (China plan §3, §28, §30).
    ///
    /// Downloads go to the CDN configured here, never to Hugging Face, and the app is fully
    /// usable while this says "not downloaded" — the card exists to make the *optional* nature
    /// of the 350 MB obvious rather than to gate anything.
    @ViewBuilder
    private var localModelRows: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 13))
                .foregroundStyle(modelManager.state.isReady ? Theme.accent : Theme.mutedInk)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(modelManager.descriptor.displayName)
                    .foregroundStyle(Theme.ink)
                Text("\(modelManager.descriptor.detail) · \(Self.sizeDescription(modelManager.descriptor.approximateBytes))")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedInk)
                Text(modelStatusDescription)
                    .font(.caption)
                    .foregroundStyle(modelManager.state.isReady ? Theme.accent : Theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, AppMetrics.rowVertical)

        if case let .downloading(fraction) = modelManager.state {
            ProgressView(value: max(0, min(fraction, 1)))
                .padding(.vertical, AppMetrics.rowVertical)
        }

        HStack(spacing: 10) {
            switch modelManager.state {
            case .downloading:
                Button {
                    modelManager.cancelDownload()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            case .installed:
                Button(role: .destructive) {
                    modelManager.deleteModel()
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }
            default:
                Button {
                    Task { await modelManager.download() }
                } label: {
                    Label("Download Model", systemImage: "arrow.down.circle")
                }
                .disabled(!canStartModelDownload)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppMetrics.rowVertical)

        if !LocalModelManager.isDownloadConfigured {
            rowDivider
            VStack(alignment: .leading, spacing: 4) {
                Text("Model download server")
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                Text("Point this at the CDN that serves model-manifest.json. Runtime downloads never use Hugging Face.")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://…/qwen3-0.6b-4bit/", text: $modelManifestURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { modelManager.manifestURL = LocalModelManager.configuredManifestURL() }
            }
            .padding(.vertical, AppMetrics.rowVertical)
        }
    }

    private var canStartModelDownload: Bool {
        // An ineligible device can never run the model, so offering the download would only
        // waste 350 MB of the user's bandwidth.
        if case .unsupportedDevice = modelManager.state { return false }
        return LocalModelManager.isDownloadConfigured
    }

    private var modelStatusDescription: String {
        switch modelManager.state {
        case .installed(let version, let bytes):
            return String(localized: "Installed · v\(version) · \(Self.sizeDescription(bytes))")
        case .downloading(let fraction):
            return String(localized: "Downloading… \(Int(fraction * 100))%")
        case .notInstalled:
            return String(localized: "Not downloaded")
        case .unsupportedDevice(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }

    static func sizeDescription(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// What this install can actually do right now, so "why didn't local AI work?" never has
    /// to be guessed (China plan §30).
    @ViewBuilder
    private var localCapabilityRows: some View {
        if let capabilities {
            capabilityRow(title: "OCR",
                          status: capabilities.visionOCR,
                          fallback: String(localized: "Apple Vision · fully offline"))
            rowDivider
            capabilityRow(title: String(localized: "Basic text processing"),
                          status: capabilities.localNoteEngine,
                          fallback: String(localized: "ClipNest Local Lite · fully offline"))
            rowDivider
            capabilityRow(title: String(localized: "Enhanced AI"),
                          status: capabilities.enhancedModel,
                          fallback: LocalModelDescriptor.qwen3.displayName)
            if capabilities.sentenceEmbedding.isAvailable {
                rowDivider
                capabilityRow(title: String(localized: "Semantic Search"),
                              status: capabilities.sentenceEmbedding,
                              fallback: String(localized: "Apple Natural Language · fully offline"))
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking on-device capabilities…")
                    .font(.callout)
                    .foregroundStyle(Theme.mutedInk)
            }
            .padding(.vertical, AppMetrics.rowVertical)
        }
    }

    private func capabilityRow(title: String,
                               status: LocalAICapabilities.Status,
                               fallback: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(status.isAvailable ? Theme.accent : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(status.isAvailable ? (fallback ?? status.detail) : status.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppMetrics.rowVertical)
    }

    /// The OpenAI-compatible settings, unchanged from before — just relocated.
    @ViewBuilder
    private var onlineAISettings: some View {
        TextField("Base URL", text: $aiBaseURL)
            .textFieldStyle(.plain)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .padding(.vertical, AppMetrics.rowVertical)
        rowDivider
        TextField("Model", text: $aiModel)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .padding(.vertical, AppMetrics.rowVertical)
        rowDivider
        SecureField("API Key (stored in Keychain)", text: $apiKey)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(.vertical, AppMetrics.rowVertical)
        rowDivider
        Picker("Output Language", selection: $preferredLanguage) {
            ForEach(PreferredLanguage.allCases) { language in
                Text(language.title).tag(language.rawValue)
            }
        }
        .padding(.vertical, AppMetrics.rowVertical)
        rowDivider
        Toggle(isOn: $imageUsesSeparateEndpoint) {
            Label("Use a separate model for photos", systemImage: "photo.tv")
        }
        .padding(.vertical, AppMetrics.rowVertical)
        if imageUsesSeparateEndpoint {
            TextField("Image Base URL", text: $imageBaseURL)
                .textFieldStyle(.plain)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .padding(.vertical, AppMetrics.rowVertical)
            rowDivider
            TextField("Image Model", text: $imageModel)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.vertical, AppMetrics.rowVertical)
            rowDivider
            SecureField("Image API Key (stored in Keychain)", text: $imageAPIKey)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.vertical, AppMetrics.rowVertical)
        }
        Text("When enabled, photos are sent directly to the image model (it must support images). When off, photos are only OCR-read on device and the recognized text goes to the text model. In On-Device mode the image model is never called.")
            .font(.caption)
            .foregroundStyle(Theme.mutedInk)
            .padding(.bottom, AppMetrics.rowVertical)
        rowDivider
        HStack(spacing: 12) {
            Button {
                saveAISettings()
            } label: {
                Label("Save AI Settings", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            if aiSettingsSaved {
                Label("Saved", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .padding(.vertical, AppMetrics.rowVertical)
    }

    // MARK: - Obsidian shortcut

    /// What the Obsidian sheet asked for, replayed after it dismisses.
    private enum ObsidianAction {
        case switchTo(URL)
        case browse
    }

    /// Scan Obsidian's default folders off the main actor, then show what we found.
    private func beginObsidianScan() {
        guard !isScanningObsidian else { return }
        isScanningObsidian = true
        let recent = store.recentVaults
        let current = store.rootURL?.standardizedFileURL
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ObsidianVaultLocator.discoverVaults(includingRecent: recent)
            }.value
            obsidianVaults = found.filter { $0.url.standardizedFileURL != current }
            isScanningObsidian = false
            showObsidianSheet = true
        }
    }

    private func runPendingObsidianAction() {
        guard let action = pendingObsidianAction else { return }
        pendingObsidianAction = nil
        switch action {
        case .switchTo(let url):
            pendingVaultURL = url
            showSwitchVaultConfirmation = true
        case .browse:
            // Land the picker inside Obsidian's own folder when we know where it is, so the
            // shortcut stays a shortcut even on the fallback path.
            store.requestOpenVault(startingAt: ObsidianVaultLocator.defaultRoots
                .first { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    private func saveAISettings() {
        AIConfigurationStore.save(
            AIConfiguration(
                baseURL: aiBaseURL,
                apiKey: apiKey,
                model: aiModel,
                preferredLanguage: PreferredLanguage(rawValue: preferredLanguage) ?? .automatic
            )
        )
        AIConfigurationStore.saveImageConfiguration(
            AIImageConfiguration(usesSeparateEndpoint: imageUsesSeparateEndpoint,
                                 baseURL: imageBaseURL,
                                 apiKey: imageAPIKey,
                                 model: imageModel)
        )
        aiSettingsSaved = true
    }

    // MARK: - Layout helpers

    /// A settings group: a small caps header sitting close above its card, and uniform
    /// spacing between groups. Keeps every section visually identical by construction.
    private func sectionCard<Content: View>(_ title: LocalizedStringKey,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mutedInk)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, AppMetrics.cardPadding)
            .background(Theme.card,
                        in: RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline))
            .tint(Theme.accent)
        }
    }

    /// Divider aligned with the row text instead of bleeding to the card edge.
    private var rowDivider: some View {
        Divider().padding(.leading, AppMetrics.cardPadding)
    }
}
