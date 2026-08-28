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

    @AppStorage(ClipNestSettings.autoClassify) private var autoClassify = true
    @AppStorage(ClipNestSettings.allowNewCategories) private var allowNewCategories = false
    @AppStorage(ClipNestSettings.defaultCategory) private var defaultCategory = ClassificationService.inbox

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showSwitchVaultConfirmation = false
    @State private var pendingVaultURL: URL?
    @State private var showCloseVaultConfirmation = false

    init() {
        let configuration = AIConfigurationStore.load()
        _aiBaseURL = State(initialValue: configuration.baseURL)
        _aiModel = State(initialValue: configuration.model)
        _preferredLanguage = State(initialValue: configuration.preferredLanguage.rawValue)
        _apiKey = State(initialValue: configuration.apiKey)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.largeTitle.bold())

                // Vault
                Text("VAULT").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedInk)
                VStack(alignment: .leading, spacing: 0) {
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
                    .padding(.vertical, 14)
                    Divider()
                    Button {
                        pendingVaultURL = nil
                        showSwitchVaultConfirmation = true
                    } label: {
                        Label("Open Another Folder…", systemImage: "folder.badge.plus")
                    }
                    .padding(.vertical, 14)
                    Divider()
                    Button(role: .destructive) {
                        showCloseVaultConfirmation = true
                    } label: {
                        Label("Close Vault", systemImage: "xmark.circle")
                    }
                    .padding(.vertical, 14)
                }
                .padding(.horizontal, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))

                // Recent vaults — one-click switching, Obsidian-style.
                let others = store.recentVaults.filter { $0.standardizedFileURL != store.rootURL?.standardizedFileURL }
                if !others.isEmpty {
                    Text("RECENT VAULTS").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedInk)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.element) { index, url in
                            if index > 0 { Divider() }
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
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from recent list")
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                }

                Text("CLIPBOARD").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedInk)
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $autoDetectClipboard) {
                        Label("自动检测剪贴板", systemImage: "doc.on.clipboard")
                    }
                    .padding(.vertical, 12)
                    Divider()
                    Toggle(isOn: $autoGenerateNote) {
                        Label("自动生成笔记", systemImage: "sparkles")
                    }
                    .padding(.vertical, 12)
                    Divider()
                    Picker("处理模式", selection: $processingMode) {
                        ForEach(ClipboardProcessingMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .padding(.vertical, 12)
                    Text(ClipboardProcessingMode(rawValue: processingMode)?.description ?? "")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, 12)
                    Divider()
                    Button {
                        Task { await captureCoordinator.reprocessClipboard() }
                    } label: {
                        Label("重新整理当前剪贴板", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .tint(Theme.accent)

                Text("AI").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedInk)
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Base URL", text: $aiBaseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .padding(.vertical, 12)
                    Divider()
                    TextField("Model", text: $aiModel)
                        .autocorrectionDisabled()
                        .padding(.vertical, 12)
                    Divider()
                    SecureField("API Key（保存在钥匙串）", text: $apiKey)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(.vertical, 12)
                    Divider()
                    Picker("输出语言", selection: $preferredLanguage) {
                        ForEach(PreferredLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .padding(.vertical, 12)
                    Text("ClipNest 使用 OpenAI-compatible Chat Completions 接口，并通过系统钥匙串保存 API Key。")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, 12)
                    Divider()
                    HStack(spacing: 12) {
                        Button {
                            saveAISettings()
                        } label: {
                            Label("保存 AI 设置", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        if aiSettingsSaved {
                            Label("已保存", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .tint(Theme.accent)
                .onChange(of: aiBaseURL) { _, _ in aiSettingsSaved = false }
                .onChange(of: aiModel) { _, _ in aiSettingsSaved = false }
                .onChange(of: preferredLanguage) { _, _ in aiSettingsSaved = false }
                .onChange(of: apiKey) { _, _ in aiSettingsSaved = false }

                Text("CLASSIFICATION").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedInk)
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $autoClassify) {
                        Label("自动分类", systemImage: "folder.badge.gearshape")
                    }
                    .padding(.vertical, 12)
                    Divider()
                    Toggle(isOn: $allowNewCategories) {
                        Label("允许创建新分类", systemImage: "folder.badge.plus")
                    }
                    .padding(.vertical, 12)
                    Divider()
                    TextField("默认分类", text: $defaultCategory)
                        .padding(.vertical, 12)
                    Text("关闭自动分类或无法匹配时使用默认分类；如果分类不存在，内容会保存到 Inbox。")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .tint(Theme.accent)

                // Display
                Text("DISPLAY").font(.caption.weight(.semibold)).foregroundStyle(Theme.mutedInk)
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $store.showHiddenFiles) {
                        Label("Show Hidden Files", systemImage: "eye")
                    }
                    .padding(.vertical, 12)
                    Divider()
                    Toggle(isOn: $previewDefault) {
                        Label("Open Notes in Preview", systemImage: "doc.text.image")
                    }
                    .padding(.vertical, 12)
                    #if os(macOS)
                    Divider()
                    Toggle(isOn: $multipleTabs) {
                        Label("Show Multiple Editor Tabs", systemImage: "rectangle.split.3x1")
                    }
                    .padding(.vertical, 12)
                    #endif
                }
                .padding(.horizontal, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .tint(Theme.accent)
            }
            .padding(22)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .alert("确认切换目录？", isPresented: $showSwitchVaultConfirmation) {
            Button("继续选择目录") {
                if let pendingVaultURL {
                    store.openVault(at: pendingVaultURL)
                    self.pendingVaultURL = nil
                } else {
                    store.requestOpenVault()
                }
            }
            Button("取消", role: .cancel) {
                pendingVaultURL = nil
            }
        } message: {
            Text("切换目录后，ClipNest 将停止使用当前 Vault；磁盘上的文件不会被删除。")
        }
        .alert("确认关闭目录？", isPresented: $showCloseVaultConfirmation) {
            Button("关闭目录", role: .destructive) {
                store.closeVault()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("关闭只会移除 ClipNest 当前打开的 Vault，不会删除目录中的文件。")
        }
        .onChange(of: autoDetectClipboard) { _, enabled in
            guard enabled else { return }
            Task { await captureCoordinator.sceneDidBecomeActive() }
        }
        // Bridge the importer used elsewhere — settings just toggles the request flag.
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
        aiSettingsSaved = true
    }
}
