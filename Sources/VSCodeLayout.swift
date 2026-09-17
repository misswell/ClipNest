#if os(macOS)
import SwiftUI
import AppKit

/// The full VS Code-style desktop shell:
/// Activity bar · collapsible Explorer/Search side bar · editor · collapsible terminal panel.
struct VSCodeLayout: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject private var selection: VaultSelection
    /// Vault-wide search, so the top bar's palette can surface content hits, not just names.
    @EnvironmentObject var search: LocalSearchController
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    @StateObject private var terminals = TerminalController()

    @State private var activity: ActivityItem = .explorer
    @State private var sidebarVisible = true
    @State private var terminalVisible = false

    @State private var sidebarWidth: CGFloat = 260
    @State private var terminalWidth: CGFloat = 520
    @State private var dragStartSidebar: CGFloat?
    @State private var dragStartTerminal: CGFloat?

    @State private var showSettings = false
    @State private var showImageImporter = false
    @AppStorage(EditorMode.persistenceKey) private var storedEditorMode = EditorMode.edit.rawValue
    @State private var showQuickOpen = false
    @State private var activeExtension: String?
    @AppStorage("editor.multipleTabs") private var multipleTabs = true
    @State private var openTabs: [URL] = []

    private var editorMode: Binding<EditorMode> {
        Binding(
            get: { EditorMode(rawValue: storedEditorMode) ?? .edit },
            set: { storedEditorMode = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                ActivityBar(selection: $activity,
                            sidebarVisible: $sidebarVisible,
                            onSettings: { showSettings = true })

                if sidebarVisible {
                    sidebar
                        .frame(width: sidebarWidth)
                    DragDivider(onChanged: { dx in
                        let start = dragStartSidebar ?? sidebarWidth
                        if dragStartSidebar == nil { dragStartSidebar = start }
                        sidebarWidth = min(560, max(170, start + dx))
                    }, onEnded: { dragStartSidebar = nil })
                }

                editorArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if terminalVisible {
                    DragDivider(onChanged: { dx in
                        let start = dragStartTerminal ?? terminalWidth
                        if dragStartTerminal == nil { dragStartTerminal = start }
                        terminalWidth = min(1100, max(280, start - dx))
                    }, onEnded: { dragStartTerminal = nil })
                    TerminalPanel(controller: terminals,
                                  directory: store.rootURL?.path,
                                  onClose: { terminalVisible = false })
                        .frame(width: terminalWidth)
                }
            }
            statusBar
        }
        .background(VSCode.editorBg)
        .background(WindowAccessor())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .overlay { quickOpenOverlay }
        .task { store.restoreVaultIfNeeded() }
        .task { AppIconManager.applyStoredMacIcon() }
        // Bridge the "Open Vault Folder…" command / sidebar button to a native folder picker.
        .onChange(of: store.openVaultRequested) { _, requested in
            if requested {
                store.openVaultRequested = false
                presentOpenVaultPanel()
            }
        }
        // Safety net: re-sync the tree when the app regains focus (e.g. after editing
        // files in Finder or another tool), on top of the live FSEvents watcher.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .modifier(DesktopNotificationBridges(
            onToggleTerminal: { terminalVisible.toggle() },
            onToggleSidebar: { sidebarVisible.toggle() },
            onNewTerminal: {
                terminalVisible = true
                terminals.newTerminal(directory: store.rootURL?.path ?? NSHomeDirectory())
            },
            onOpenTerminalAt: { path in
                terminalVisible = true
                terminals.newTerminal(directory: path)
            },
            onQuickOpen: { showQuickOpen = true },
            onQuickPaste: { captureClipboard() },
            onImportImage: { presentImageImporter() },
            onOpenExtension: { activeExtension = $0 }
        ))
        .onChange(of: selection.fileURL) { _, url in openTab(url) }
        .onChange(of: store.lastDocumentMove) { _, move in
            guard let move else { return }
            updateOpenTabs(for: move)
        }
        .onChange(of: multipleTabs) { _, multi in
            if !multi { openTabs = selection.fileURL.map { [$0] } ?? [] }
        }
        .sheet(isPresented: $showSettings) { sheet { SettingsView() } }
        // The Mac counterpart of the phone's photo-library button. `PHPickerViewController` is
        // iOS-only, so the desktop picks an image file and feeds the same capture path.
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            Task { await captureCoordinator.captureImportedImage(at: url) }
        }
        .sheet(item: Binding(get: { activeExtension.map { IdentifiedString($0) } },
                             set: { activeExtension = $0?.value })) { item in
            switch item.value {
            case "wiki-llm":
                WikiPanel(runInTerminal: runInTerminal, onClose: { activeExtension = nil })
            case "github":
                GitHubPanel(runInTerminal: runInTerminal, onClose: { activeExtension = nil })
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Side bar content
    @ViewBuilder
    private var sidebar: some View {
        switch activity {
        case .explorer:   ExplorerSidebar(selection: selection)
        case .search:     SearchSidebar()
        case .extensions: ExtensionsSidebar()
        }
    }

    private func runInTerminal(_ command: String) {
        terminalVisible = true
        terminals.newTerminal(directory: store.rootURL?.path ?? NSHomeDirectory(), run: command)
    }

    // MARK: - Editor area
    private var displayedTabs: [URL] {
        multipleTabs ? openTabs : (selection.fileURL.map { [$0] } ?? [])
    }

    private func openTab(_ url: URL?) {
        guard let url else { return }
        if multipleTabs {
            if !openTabs.contains(url) { openTabs.append(url) }
        } else {
            openTabs = [url]
        }
    }

    private func closeTab(_ url: URL) {
        openTabs.removeAll { $0 == url }
        if selection.fileURL == url { selection.fileURL = openTabs.last }
    }

    private func updateOpenTabs(for move: VaultDocumentMove) {
        var updated: [URL] = []
        for tab in openTabs {
            let candidate = tab.standardizedFileURL == move.source.standardizedFileURL
                ? move.destination
                : tab
            if !updated.contains(candidate) { updated.append(candidate) }
        }
        openTabs = updated
    }

    /// Native folder chooser — pick any local folder of Markdown to open as a vault,
    /// the same way Obsidian opens a vault.
    private func presentOpenVaultPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Vault"
        panel.message = "Choose a folder of Markdown files to open as a vault."
        panel.directoryURL = store.openVaultStartingDirectory ?? store.rootURL
        store.openVaultStartingDirectory = nil
        if panel.runModal() == .OK, let url = panel.url {
            store.openVault(at: url)
        }
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            if !displayedTabs.isEmpty {
                editorTabBar
                Divider().overlay(VSCode.border)
            }
            Group {
                if let url = selection.fileURL {
                    let node = FileNode(url: url, name: url.lastPathComponent, isDirectory: false, children: nil)
                    if node.isEditable {
                        EditorPane(url: url, mode: editorMode)
                    } else if node.isImage {
                        ImageFileView(url: url)
                    } else {
                        welcome
                    }
                } else {
                    welcome
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VSCode.editorBg)
    }

    @ViewBuilder
    private var editorTabBar: some View {
        let isEditable = selection.fileURL.map {
            FileNode.editableExtensions.contains($0.pathExtension.lowercased())
        } ?? false
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(displayedTabs, id: \.self) { url in
                        editorTab(url)
                    }
                }
            }
            Spacer(minLength: 8)
            if isEditable {
                ModeToggle(mode: editorMode).padding(.trailing, 10)
            }
        }
        .frame(height: 35)
        .background(VSCode.tabBarBg)
    }

    private func editorTab(_ url: URL) -> some View {
        let active = selection.fileURL == url
        return HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11)).foregroundStyle(Color(hex: 0x6FB3D2))
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(active ? VSCode.fg : VSCode.muted)
                .lineLimit(1)
            Button { closeTab(url) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(VSCode.muted).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 35)
        .background(active ? VSCode.tabActiveBg : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(active ? VSCode.accent : Color.clear).frame(height: 1) }
        .overlay(alignment: .trailing) { Divider().overlay(VSCode.border) }
        .contentShape(Rectangle())
        .onTapGesture { selection.fileURL = url }
    }

    /// Extracted from `body` for the same type-checker reason as `DesktopNotificationBridges`:
    /// this palette's two closures were among the heaviest sub-expressions in the chain.
    @ViewBuilder
    private var quickOpenOverlay: some View {
        if showQuickOpen {
            QuickOpenPalette(isPresented: $showQuickOpen,
                             onOpen: { url in
                                 selection.fileURL = url
                             },
                             onSearchAll: { query in
                                 // Hand the query to the full side bar, which keeps the
                                 // chosen search mode visible while browsing results.
                                 search.query = query
                                 activity = .search
                                 sidebarVisible = true
                                 showQuickOpen = false
                             })
        }
    }

    /// VS Code-style title bar: traffic-light gap · centered command/search bar · layout toggles.
    private var topBar: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 72)          // space for the traffic lights
            Spacer(minLength: 8)
            commandCenter
            Spacer(minLength: 8)
            captureButtons
            Rectangle().fill(VSCode.border).frame(width: 1, height: 18)
            layoutToggleButtons
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(VSCode.activityBg)
        .overlay(alignment: .bottom) { Rectangle().fill(VSCode.border).frame(height: 1) }
    }

    /// The phone's two capture affordances — paste the clipboard, or bring in a picture — which
    /// the desktop previously only exposed as a row inside Settings. They sit in the title bar
    /// because that is the one strip the desktop always shows, where iOS has a navigation bar and
    /// a floating button to hang them on.
    private var captureButtons: some View {
        HStack(spacing: 2) {
            Button(action: captureClipboard) {
                if captureCoordinator.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 24)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14))
                        .foregroundStyle(VSCode.muted)
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(captureCoordinator.isProcessing)
            .help("Quick Paste — organize the current clipboard (⌘⇧V)")
            .accessibilityLabel("Quick Paste")

            Button(action: presentImageImporter) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 14))
                    .foregroundStyle(VSCode.muted)
                    .frame(width: 30, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(captureCoordinator.isProcessing)
            .help("Import Image — organize the text in a picture (⌘⇧I)")
            .accessibilityLabel("Import Image")
        }
    }

    private func captureClipboard() {
        guard !captureCoordinator.isProcessing else { return }
        Task { await captureCoordinator.reprocessClipboard() }
    }

    private func presentImageImporter() {
        guard !captureCoordinator.isProcessing else { return }
        showImageImporter = true
    }

    private var commandCenter: some View {
        Button { showQuickOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(VSCode.muted)
                Text(store.vaultName).font(.system(size: 12)).foregroundStyle(VSCode.fg)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: 520)
            .background(VSCode.editorBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(VSCode.border))
        }
        .buttonStyle(.plain)
        .help("Search Files (⌘P)")
    }

    private var layoutToggleButtons: some View {
        HStack(spacing: 2) {
            topToggle("sidebar.leading", on: sidebarVisible, help: "Toggle Primary Side Bar (⌘B)") {
                sidebarVisible.toggle()
            }
            topToggle("sidebar.trailing", on: terminalVisible, help: "Toggle Terminal Panel (⌃`)") {
                toggleTerminalPanel()
            }
        }
    }

    private func topToggle(_ icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(on ? VSCode.activeIcon : VSCode.muted)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleTerminalPanel() {
        if !terminalVisible && terminals.sessions.isEmpty {
            terminals.newTerminal(directory: store.rootURL?.path ?? NSHomeDirectory())
        }
        terminalVisible.toggle()
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 56)).foregroundStyle(VSCode.muted.opacity(0.4))
            Text("Select a file in the Explorer to start editing")
                .font(.system(size: 13)).foregroundStyle(VSCode.muted)
            shortcut("Toggle Terminal", "⌃`")
            shortcut("Toggle Side Bar", "⌘B")
            shortcut("New Terminal", "⌃⇧`")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSCode.editorBg)
    }

    private func shortcut(_ name: String, _ keys: String) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 12)).foregroundStyle(VSCode.muted)
            Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(VSCode.fg)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(VSCode.hoverBg, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Status bar
    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(store.vaultName, systemImage: "folder")
                .font(.system(size: 11)).foregroundStyle(.white)
            Spacer()
            Button {
                terminalVisible = true
                terminals.newTerminal(directory: store.rootURL?.path ?? NSHomeDirectory())
            } label: {
                Label("Terminal", systemImage: "terminal").font(.system(size: 11)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text("Markdown").font(.system(size: 11)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(VSCode.accent)
    }

    @ViewBuilder
    private func sheet<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        SheetContainer { content() }
    }
}

/// Wraps any sheet's content with a header that always offers a way out:
/// a visible "Done" button and the Escape key both dismiss it.
private struct SheetContainer<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Esc also dismisses
            }
            .padding(12)
            content
        }
        .frame(minWidth: 460, minHeight: 440)
    }
}

/// A thin, draggable divider that resizes an adjacent panel (VS Code style).
/// `onChanged` receives the cumulative horizontal drag offset from the gesture start.
private struct DragDivider: View {
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? VSCode.accent : VSCode.border)
            .frame(width: hovering ? 2 : 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 3)            // widen the hit target to ~7pt
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                // Track in GLOBAL space: the divider itself shifts as the panel resizes,
                // so a local translation would feed back on itself and the drag wouldn't work.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in onChanged(value.translation.width) }
                    .onEnded { _ in onEnded() }
            )
    }
}

/// ⌘P quick-open palette: fuzzy filename filter over the vault, floating from the top.
private struct QuickOpenPalette: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var search: LocalSearchController
    @Binding var isPresented: Bool
    var onOpen: (URL) -> Void
    var onSearchAll: (String) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    /// Content hits shown under the file matches. The controller owns the debounce and runs
    /// the query off the main actor, so typing stays smooth (spec §38, §43).
    private var contentResults: [SearchResult] {
        guard !trimmedQuery.isEmpty else { return [] }
        return Array(search.results.prefix(5))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                TextField("Search files and notes", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(10)
                    .focused($focused)
                    .onSubmit { openFirstResult() }
                Divider().overlay(VSCode.border)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results, id: \.self) { url in
                            Button { open(url) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(Color(hex: 0x6FB3D2))
                                    Text(url.lastPathComponent).font(.system(size: 13)).foregroundStyle(VSCode.fg)
                                    Spacer()
                                    Text(relativePath(url)).font(.system(size: 11)).foregroundStyle(VSCode.muted).lineLimit(1)
                                }
                                .padding(.horizontal, 12).frame(height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !contentResults.isEmpty {
                            sectionHeader("IN NOTE CONTENT")
                            ForEach(contentResults) { result in
                                Button { open(result.fileURL) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "text.magnifyingglass")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color(hex: 0xD7BA7D))
                                            Text(result.title)
                                                .font(.system(size: 13))
                                                .foregroundStyle(VSCode.fg)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(result.matchReason)
                                                .font(.system(size: 10))
                                                .foregroundStyle(VSCode.muted)
                                                .lineLimit(1)
                                        }
                                        if !result.snippet.isEmpty {
                                            Text(result.snippet)
                                                .font(.system(size: 11))
                                                .foregroundStyle(VSCode.muted)
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)

                if !trimmedQuery.isEmpty {
                    Divider().overlay(VSCode.border)
                    Button { onSearchAll(trimmedQuery) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11))
                            Text("Search all notes for “\(trimmedQuery)”")
                                .font(.system(size: 11))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .foregroundStyle(VSCode.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Opens the Search side bar with smart or exact matching")
                }
            }
            .frame(width: 560)
            .background(Color(hex: 0x252526), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VSCode.border))
            .shadow(radius: 24, y: 8)
            .padding(.top, 52)
        }
        .onAppear { focused = true }
        .onExitCommand { isPresented = false }
        .onChange(of: query) { _, newValue in
            // The controller debounces this and searches off the main actor.
            search.query = newValue
        }
        // Deliberately no `onDisappear` reset: the query is shared with the Search side bar,
        // and clearing it here would wipe a query the user typed there.
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(VSCode.muted)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func openFirstResult() {
        if let first = results.first {
            open(first)
        } else if let first = contentResults.first {
            open(first.fileURL)
        }
    }

    private func open(_ url: URL) { onOpen(url); isPresented = false }

    private func relativePath(_ url: URL) -> String {
        guard let root = store.rootURL else { return "" }
        return url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var results: [URL] {
        guard let root = store.rootURL else { return [] }
        var out: [URL] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in en {
                guard FileNode.editableExtensions.contains(u.pathExtension.lowercased()) else { continue }
                if query.isEmpty || u.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    out.append(u)
                    if out.count >= 200 { break }
                }
            }
        }
        return out
    }
}

/// VS Code-style search side bar. Searches note content, OCR text and semantics across the
/// vault — not just file names (spec §18, §43, §44).
private struct SearchSidebar: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var search: LocalSearchController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("SEARCH")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(VSCode.muted)
                Spacer()
                if search.isIndexing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Button {
                        search.rebuild()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(VSCode.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Rebuild the local search index")
                }
            }
            .padding(.horizontal, 12).frame(height: 35)
            Divider().overlay(VSCode.border)

            TextField("Search notes", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(6)
                .background(Color(hex: 0x3C3C3C), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Picker("", selection: $search.mode) {
                ForEach(VaultSearchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if let error = search.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { result in
                        Button { store.selectedFileURL = result.fileURL } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(hex: 0x6FB3D2))
                                    Text(result.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(VSCode.fg)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                }
                                Text(relativePath(result.fileURL))
                                    .font(.system(size: 10))
                                    .foregroundStyle(VSCode.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !result.snippet.isEmpty {
                                    Text(result.snippet)
                                        .font(.system(size: 10))
                                        .foregroundStyle(VSCode.muted)
                                        .lineLimit(2)
                                }
                                Text(result.matchReason)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color(hex: 0x6FB3D2))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if search.results.isEmpty, !search.query.isEmpty, !search.isIndexing {
                        Text(search.hasIndex ? "No matches" : "Indexing the vault…")
                            .font(.system(size: 11))
                            .foregroundStyle(VSCode.muted)
                            .padding(12)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(VSCode.sidebarBg)
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = store.rootURL else { return url.lastPathComponent }
        return url.deletingLastPathComponent().path
            .replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Makes the window title bar transparent and full-size so our custom top bar shares the
/// same row as the traffic-light buttons (VS Code style).
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            // Must stay false: when true, AppKit swallows drags on "background" views
            // (like the resize dividers) to move the window. The title bar still moves it.
            w.isMovableByWindowBackground = false
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Lightweight Identifiable wrapper so a String can drive `.sheet(item:)`.
struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
    init(_ value: String) { self.value = value }
}

/// The notification bridges the desktop shell listens to, lifted out of `body`.
///
/// This is not only tidiness. `body` is already a long chain of modifiers, and adding the two
/// capture bridges to it made CI's compiler give up with "unable to type-check this expression in
/// reasonable time" — a newer local Xcode accepted the same code, so the failure was invisible
/// here. Collecting every bridge into one modifier leaves `body` with fewer modifiers than it had
/// before the capture buttons existed, which is what makes the fix safe rather than hopeful.
private struct DesktopNotificationBridges: ViewModifier {
    let onToggleTerminal: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTerminal: () -> Void
    let onOpenTerminalAt: (String) -> Void
    let onQuickOpen: () -> Void
    let onQuickPaste: () -> Void
    let onImportImage: () -> Void
    let onOpenExtension: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleTerminal)) { _ in
                onToggleTerminal()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                onToggleSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTerminal)) { _ in
                onNewTerminal()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTerminalAt)) { note in
                if let path = note.object as? String { onOpenTerminalAt(path) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickOpen)) { _ in
                onQuickOpen()
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickPasteCapture)) { _ in
                onQuickPaste()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importImageCapture)) { _ in
                onImportImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openExtension)) { note in
                onOpenExtension(note.object as? String)
            }
    }
}

extension Notification.Name {
    static let toggleTerminal = Notification.Name("toggleTerminal")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let newTerminal = Notification.Name("newTerminal")
    static let quickOpen = Notification.Name("quickOpen")
    /// Capture the current clipboard, and bring in a picture. Wired from the Capture menu so
    /// the menu items and the title-bar buttons drive one code path.
    static let quickPasteCapture = Notification.Name("quickPasteCapture")
    static let importImageCapture = Notification.Name("importImageCapture")
}
#endif
