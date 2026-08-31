import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The main two-pane vault browser: file/folder tree on the left, editor/preview on the right.
struct VaultView: View {
    @EnvironmentObject var store: VaultStore
    @State private var showImporter = false

    // Name-entry dialogs
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var newName = ""
    @State private var creationDirectory: URL?

    // Rename
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @State private var moveTarget: MoveDocumentTarget?

    var body: some View {
        VaultNavigationHost(
            onNewFile: { directory in startNewFile(in: directory) },
            onNewFolder: { directory in startNewFolder(in: directory) },
            onRename: { url, name in
                renameTarget = url
                renameText = name
            },
            onMove: { url in moveTarget = MoveDocumentTarget(url: url) },
            onDelete: { store.delete($0) },
            onMoveInOrder: { url, direction in
                _ = store.moveDocumentInOrder(url, direction: direction)
            }
        )
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { store.openVault(at: url) }
        }
        // Bridge macOS menu commands
        .onChange(of: store.openVaultRequested) { _, v in if v { showImporter = true; store.openVaultRequested = false } }
        .onChange(of: store.newFileRequested) { _, v in if v { startNewFile(); store.newFileRequested = false } }
        // New file / folder dialogs
        .alert("New Markdown File", isPresented: $showNewFile) {
            TextField("Name", text: $newName)
            Button("Create") {
                let directory = creationDirectory
                creationDirectory = nil
                store.createFile(named: newName, in: directory)
            }
            Button("Cancel", role: .cancel) { creationDirectory = nil }
        } message: {
            Text("Created in \((creationDirectory ?? store.targetDirectory() ?? store.rootURL)?.lastPathComponent ?? store.vaultName)")
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newName)
            Button("Create") {
                let directory = creationDirectory
                creationDirectory = nil
                store.createFolder(named: newName, in: directory)
            }
            Button("Cancel", role: .cancel) { creationDirectory = nil }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let t = renameTarget { store.rename(t, to: renameText) }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .sheet(item: $moveTarget) { target in
            MoveDocumentView(fileURL: target.url) { moveTarget = nil }
                .environmentObject(store)
        }
    }

    // MARK: - Dialog launchers
    private func startNewFile(in directory: URL? = nil) {
        creationDirectory = directory ?? store.targetDirectory()
        newName = "Untitled"
        showNewFile = true
    }

    private func startNewFolder(in directory: URL? = nil) {
        creationDirectory = directory ?? store.targetDirectory()
        newName = "New Folder"
        showNewFolder = true
    }
}

/// Owns the split-view route and its recursive explorer state. A document tap therefore updates
/// only this subtree; the outer shell stays stable while NavigationSplitView performs its push.
private struct VaultNavigationHost: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    @EnvironmentObject private var vaultTabTracker: VaultTabTracker
    #if os(iOS)
    @State private var sidebarPhotoPicker = false
    #endif
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var expandedFolders: Set<URL> = []
    @State private var navigationSelection: URL?

    let onNewFile: (URL?) -> Void
    let onNewFolder: (URL?) -> Void
    let onRename: (URL, String) -> Void
    let onMove: (URL) -> Void
    let onDelete: (URL) -> Void
    let onMoveInOrder: (URL, VaultMoveDirection) -> Void

    #if os(iOS)
    private var pickPhotoAction: () -> Void {
        {
            NSLog("VV: pickPhotoAction fired, setting sidebarPhotoPicker = true")
            sidebarPhotoPicker = true
            NSLog("VV: sidebarPhotoPicker now = %d", sidebarPhotoPicker ? 1 : 0)
        }
    }
    #else
    private var pickPhotoAction: () -> Void { {} }
    #endif

    /// A human cannot realistically switch tabs and tap a note row within the window;
    /// a passthrough tap always does. The stamp comes from the tab switch itself, so it
    /// can never be refreshed by anything happening inside this screen.
    private var withinTabSwitchGrace: Bool {
        Date().timeIntervalSince(vaultTabTracker.vaultTabActivatedAt) < 0.35
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
            VaultSidebar(
                onPickPhoto: pickPhotoAction,
                navigationSelection: $navigationSelection,
                expandedFolders: $expandedFolders,
                expansionSnapshot: expandedFolders,
                treeRevision: store.treeRevision,
                onNewFile: onNewFile,
                onNewFolder: onNewFolder,
                onRename: onRename,
                onMove: onMove,
                onSelect: selectFile,
                onDelete: onDelete,
                onMoveInOrder: onMoveInOrder
            )
            .equatable()
            .navigationTitle(store.vaultName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } detail: {
            detail
                #if os(iOS)
                .sheet(isPresented: $sidebarPhotoPicker) {
                    PhotoLibraryPicker { image in
                        sidebarPhotoPicker = false
                        guard let image else { return }
                        Task { await captureCoordinator.capturePhoto(image) }
                    }
                    .ignoresSafeArea()
                }
                #endif
            }

            if navigationSelection == nil, store.rootURL != nil {
                quickPasteButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .background(
            VaultSelectionNavigationBridge(
                selection: store.selection,
                navigationSelection: $navigationSelection
            )
        )
        .task {
            store.restoreVaultIfNeeded()
            navigationSelection = store.selectedFileURL
        }
        #if os(iOS)
        // sheet temporarily removed for bisect
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if let url = navigationSelection {
            // Every selection path in the iOS tree explicitly selects a file. Folders only
            // update DisclosureGroup expansion, so avoid a synchronous filesystem stat while
            // NavigationSplitView is animating into the detail column.
            let node = FileNode(url: url, name: url.lastPathComponent,
                                isDirectory: false, children: nil)
            if node.isEditable {
                MarkdownEditorView(url: url)
            } else if node.isImage {
                ImageFileView(url: url)
            } else {
                ContentUnavailableView("Unsupported File",
                                       systemImage: "doc",
                                       description: Text(url.lastPathComponent))
            }
        } else {
            VaultHomeView(onSelect: selectFile)
        }
    }

    private var quickPasteButton: some View {
        Button {
            Task { await captureCoordinator.reprocessClipboard() }
        } label: {
            HStack(spacing: 8) {
                if captureCoordinator.isProcessing {
                    ProgressView()
                        .tint(.white)
                }
                Image(systemName: "doc.on.clipboard")
                    .font(.subheadline.weight(.bold))
                Text("Quick Paste")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(Theme.primary, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(captureCoordinator.isProcessing)
        .accessibilityLabel("Quick Paste")
        .accessibilityHint("Capture the current clipboard content")
    }

    private func selectFile(_ url: URL) {
        guard navigationSelection != url else { return }
        navigationSelection = url
        // Keep service code (capture/wiki actions) pointed at the same file without making the
        // navigation state wait for the global selection publisher.
        store.selectedFileURL = url
    }
}

/// The iOS sidebar is kept in its own subtree so changes to the detail route do not force the
/// parent NavigationSplitView to rebuild the complete recursive list. The selection binding is
/// still supplied to List for compact-width navigation, while file rows select explicitly.
private struct VaultSidebar: View, Equatable {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    let onPickPhoto: () -> Void
    @Binding var navigationSelection: URL?
    @Binding var expandedFolders: Set<URL>
    /// A value snapshot used only by `EquatableView`; the selection binding is deliberately not
    /// part of it because changing a document must not rebuild the recursive tree.
    let expansionSnapshot: Set<URL>
    let treeRevision: UInt64
    let onNewFile: (URL?) -> Void
    let onNewFolder: (URL?) -> Void
    let onRename: (URL, String) -> Void
    let onMove: (URL) -> Void
    let onSelect: (URL) -> Void
    let onDelete: (URL) -> Void
    let onMoveInOrder: (URL, VaultMoveDirection) -> Void

    static func == (lhs: VaultSidebar, rhs: VaultSidebar) -> Bool {
        lhs.treeRevision == rhs.treeRevision && lhs.expansionSnapshot == rhs.expansionSnapshot
    }

    var body: some View {
        Group {
            if store.rootNode == nil {
                if store.rootURL != nil, store.isTreeLoading {
                    ProgressView("Loading Vault…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                } else {
                    emptyVault
                }
            } else {
                // File rows set selection explicitly because nested DisclosureGroup rows do
                // not reliably emit List selection events on iOS.
                List(selection: $navigationSelection) {
                    if let children = store.rootNode?.children {
                        if children.isEmpty {
                            Text("This vault is empty.\nUse + to create a note.")
                                .font(.callout)
                                .foregroundStyle(Theme.mutedInk)
                        }
                        let availabilityByURL = fileTreeMoveAvailabilities(for: children)
                        ForEach(children) { node in
                            let availability = availabilityByURL[node.url] ?? .none
                            VaultTreeNode(
                                node: node,
                                expanded: $expandedFolders,
                                onNewFile: { onNewFile($0) },
                                onNewFolder: { onNewFolder($0) },
                                onRename: onRename,
                                onMove: onMove,
                                onSelect: onSelect,
                                onDelete: onDelete,
                                onMoveInOrder: onMoveInOrder,
                                canMoveUp: availability.up,
                                canMoveDown: availability.down
                            )
                        }
                    }
                }
                .listStyle(.sidebar)
                #if os(iOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 76)
                }
                #endif
                .toolbar { sidebarToolbar }
            }
        }
    }

    private var emptyVault: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text("Open a Vault")
                .font(.title2.bold())
            Text("Choose any local folder of Markdown files — fully compatible with your Obsidian vault.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.mutedInk)
                .frame(maxWidth: 320)
            Button {
                store.requestOpenVault()
            } label: {
                Label("Open Folder…", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)

            Button {
                store.openSampleVault()
            } label: {
                Label("Open Sample Vault", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(iOS)
            Button {
                onPickPhoto()
            } label: {
                Image(systemName: "photo.on.rectangle")
            }
            .help("Capture Photo")
            #endif
            Menu {
                Button { onNewFile(nil) } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                Button { onNewFolder(nil) } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Divider()
                Button { store.requestOpenVault() } label: {
                    Label("Open Vault…", systemImage: "folder")
                }
                Button { store.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }
}

/// Observes the service selection without making VaultView observe it. User taps update the
/// local navigation state first, so this only handles selections made by background services.
private struct VaultSelectionNavigationBridge: View {
    @ObservedObject var selection: VaultSelection
    @Binding var navigationSelection: URL?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                sync()
            }
            .onChange(of: selection.fileURL) { _, _ in
                sync()
            }
    }

    private func sync() {
        guard navigationSelection != selection.fileURL else { return }
        navigationSelection = selection.fileURL
    }
}

/// Recursive iOS file tree. Folder rows are disclosure controls only; they never become
/// the selected detail item, so tapping a folder cannot open the unsupported-file view.
private struct VaultTreeNode: View {
    let node: FileNode
    @Binding var expanded: Set<URL>
    let onNewFile: (URL) -> Void
    let onNewFolder: (URL) -> Void
    let onRename: (URL, String) -> Void
    let onMove: (URL) -> Void
    let onSelect: (URL) -> Void
    let onDelete: (URL) -> Void
    let onMoveInOrder: (URL, VaultMoveDirection) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansionBinding) {
                let children = node.children ?? []
                let availabilityByURL = fileTreeMoveAvailabilities(for: children)
                ForEach(children) { child in
                    let availability = availabilityByURL[child.url] ?? .none
                    VaultTreeNode(node: child,
                                  expanded: $expanded,
                                  onNewFile: onNewFile,
                                  onNewFolder: onNewFolder,
                                  onRename: onRename,
                                  onMove: onMove,
                                  onSelect: onSelect,
                                  onDelete: onDelete,
                                  onMoveInOrder: onMoveInOrder,
                                  canMoveUp: availability.up,
                                  canMoveDown: availability.down)
                }
            } label: {
                Label(node.name, systemImage: node.systemImage)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .selectionDisabled(true)
            .contextMenu { contextMenu }
        } else {
            Button {
                // Do not rely on List(selection:) for nested DisclosureGroup rows.
                // An explicit action keeps files clickable at every folder depth.
                onSelect(node.url)
            } label: {
                Label(node.name, systemImage: node.systemImage)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Keep the row associated with the selected URL so NavigationSplitView can
            // push the editor on iPhone after the explicit button action runs.
            .tag(node.url)
            .contextMenu { contextMenu }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.url) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(node.url)
                } else {
                    expanded.remove(node.url)
                }
            }
        )
    }

    @ViewBuilder
    private var contextMenu: some View {
        if node.isDirectory {
            Button { onNewFile(node.url) } label: {
                Label("New File Here", systemImage: "doc.badge.plus")
            }
            Button { onNewFolder(node.url) } label: {
                Label("New Folder Here", systemImage: "folder.badge.plus")
            }
            Divider()
        }
        Button { onRename(node.url, node.name) } label: {
            Label("Rename", systemImage: "pencil")
        }
        if !node.isDirectory {
            Divider()
            Button { onMove(node.url) } label: {
                Label("Move to Folder…", systemImage: "folder")
            }
            Button { onMoveInOrder(node.url, .up) } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)
            Button { onMoveInOrder(node.url, .down) } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)
        }
        Button(role: .destructive) { onDelete(node.url) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Simple full-bleed viewer for image attachments selected in the tree.
struct ImageFileView: View {
    let url: URL
    @State private var image: Image?
    @State private var didFinishLoading = false

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFit().padding()
            } else if didFinishLoading {
                ContentUnavailableView("Cannot Preview Image", systemImage: "photo")
            } else {
                ProgressView("Loading image…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(url.lastPathComponent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: url) {
            didFinishLoading = false
            image = nil
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            if let data, let decoded = Image(platformData: data) {
                image = decoded
            }
            didFinishLoading = true
        }
    }
}
