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

                sectionCard("AI") {
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
                    Text("When enabled, photos are sent directly to the image model (it must support images). When off, photos are only OCR-read on device and the recognized text goes to the text model.")
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
                .onChange(of: aiBaseURL) { _, _ in aiSettingsSaved = false }
                .onChange(of: aiModel) { _, _ in aiSettingsSaved = false }
                .onChange(of: preferredLanguage) { _, _ in aiSettingsSaved = false }
                .onChange(of: apiKey) { _, _ in aiSettingsSaved = false }
        .onChange(of: imageUsesSeparateEndpoint) { _, _ in aiSettingsSaved = false }
        .onChange(of: imageBaseURL) { _, _ in aiSettingsSaved = false }
        .onChange(of: imageModel) { _, _ in aiSettingsSaved = false }
        .onChange(of: imageAPIKey) { _, _ in aiSettingsSaved = false }

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
        .onAppear { iconPreference = AppIconManager.current }
        .onChange(of: iconPreference) { _, preference in
            AppIconManager.set(preference)
        }
        // Bridge the importer used elsewhere — settings just toggles the request flag.
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
