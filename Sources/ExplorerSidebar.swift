#if os(macOS)
import SwiftUI
import AppKit

/// VS Code-style EXPLORER: an uppercase section header plus a custom, tightly-spaced
/// disclosure tree of the vault's folders and Markdown files.
struct ExplorerSidebar: View {
    @EnvironmentObject var store: VaultStore
    /// The reference is passed into row views, but this container does not observe it. This
    /// keeps a document selection from invalidating the whole recursive tree.
    let selection: VaultSelection
    @State private var expanded: Set<URL> = []

    // Inline name dialogs
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var newName = ""
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @State private var moveTarget: MoveDocumentTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            Divider().overlay(VSCode.border)
            if store.rootNode == nil {
                emptyState
            } else {
                tree
            }
        }
        .background(VSCode.sidebarBg)
        .onAppear { if let r = store.rootURL { expanded.insert(r) } }
        .alert("New File", isPresented: $showNewFile) {
            TextField("name.md", text: $newName)
            Button("Create") { store.createFile(named: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("folder name", text: $newName)
            Button("Create") { store.createFolder(named: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("name", text: $renameText)
            Button("Rename") { if let t = renameTarget { store.rename(t, to: renameText) }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .sheet(item: $moveTarget) { target in
            MoveDocumentView(fileURL: target.url) { moveTarget = nil }
                .environmentObject(store)
        }
    }

    // MARK: - Header
    private var sectionHeader: some View {
        HStack {
            Text("EXPLORER")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VSCode.muted)
                .tracking(0.6)
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(VSCode.muted)
            }
            .buttonStyle(.plain)
            .help("Refresh file tree")
            .padding(.trailing, 2)
            Menu {
                Button("New File…") { newName = "Untitled.md"; showNewFile = true }
                Button("New Folder…") { newName = "New Folder"; showNewFolder = true }
                Divider()
                Picker("Sort By Name", selection: $store.sortAscending) {
                    Label("Ascending (A → Z)", systemImage: "arrow.up").tag(true)
                    Label("Descending (Z → A)", systemImage: "arrow.down").tag(false)
                }
                Divider()
                Button("Open Vault…") { store.requestOpenVault() }
                Button("Refresh") { store.refresh() }
                Button("Collapse All") { expanded = store.rootURL.map { [$0] } ?? [] }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(VSCode.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 35)
    }

    // MARK: - Tree
    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Workspace (root) row
                workspaceRow
                if let root = store.rootURL, expanded.contains(root),
                   let kids = store.rootNode?.children {
                    let availabilityByURL = fileTreeMoveAvailabilities(for: kids)
                    ForEach(kids) { child in
                        let availability = availabilityByURL[child.url] ?? .none
                        TreeNode(node: child, depth: 1, expanded: $expanded,
                                 onNewFile: { dir in store.selectedFileURL = dir; newName = "Untitled.md"; showNewFile = true },
                                 onNewFolder: { dir in store.selectedFileURL = dir; newName = "New Folder"; showNewFolder = true },
                                 onRename: { url, name in renameTarget = url; renameText = name },
                                 onMove: { url in moveTarget = MoveDocumentTarget(url: url) },
                                 onSelect: { url in store.selectedFileURL = url },
                                 onMoveInOrder: { url, direction in
                                     _ = store.moveDocumentInOrder(url, direction: direction)
                                 },
                                 onDelete: { url in store.delete(url) },
                                 selection: selection,
                                 canMoveUp: availability.up,
                                 canMoveDown: availability.down,
                                 onTerminalHere: openTerminalHere)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var workspaceRow: some View {
        Button {
            if let r = store.rootURL { toggle(r) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: (store.rootURL.map { expanded.contains($0) } ?? false) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(VSCode.fg)
                    .frame(width: 12)
                Text(store.vaultName.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(VSCode.fg)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You have not opened a vault.")
                .font(.system(size: 12)).foregroundStyle(VSCode.muted)
            Button("Open Vault") { store.requestOpenVault() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    private func openTerminalHere(_ dir: URL) {
        NotificationCenter.default.post(name: .openTerminalAt, object: dir.path)
    }
}

/// One recursive row in the explorer tree.
private struct TreeNode: View {
    let node: FileNode
    let depth: Int
    @Binding var expanded: Set<URL>
    var onNewFile: (URL) -> Void
    var onNewFolder: (URL) -> Void
    var onRename: (URL, String) -> Void
    var onMove: (URL) -> Void
    var onSelect: (URL) -> Void
    var onMoveInOrder: (URL, VaultMoveDirection) -> Void
    var onDelete: (URL) -> Void
    let selection: VaultSelection
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onTerminalHere: (URL) -> Void

    private var isExpanded: Bool { expanded.contains(node.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if node.isDirectory, isExpanded, let kids = node.children {
                let availabilityByURL = fileTreeMoveAvailabilities(for: kids)
                ForEach(kids) { child in
                    let availability = availabilityByURL[child.url] ?? .none
                    TreeNode(node: child, depth: depth + 1, expanded: $expanded,
                             onNewFile: onNewFile, onNewFolder: onNewFolder,
                             onRename: onRename, onMove: onMove,
                             onSelect: onSelect, onMoveInOrder: onMoveInOrder,
                             onDelete: onDelete, selection: selection,
                             canMoveUp: availability.up, canMoveDown: availability.down,
                             onTerminalHere: onTerminalHere)
                }
            }
        }
    }

    private var row: some View {
        TreeNodeRow(node: node,
                    depth: depth,
                    expanded: $expanded,
                    selection: selection,
                    onNewFile: onNewFile,
                    onNewFolder: onNewFolder,
                    onRename: onRename,
                    onMove: onMove,
                    onSelect: onSelect,
                    onMoveInOrder: onMoveInOrder,
                    onDelete: onDelete,
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown,
                    onTerminalHere: onTerminalHere)
    }
}

/// The row observes only the lightweight selection object. The recursive TreeNode container
/// remains stable when the active document changes.
private struct TreeNodeRow: View {
    let node: FileNode
    let depth: Int
    @Binding var expanded: Set<URL>
    @ObservedObject var selection: VaultSelection
    var onNewFile: (URL) -> Void
    var onNewFolder: (URL) -> Void
    var onRename: (URL, String) -> Void
    var onMove: (URL) -> Void
    var onSelect: (URL) -> Void
    var onMoveInOrder: (URL, VaultMoveDirection) -> Void
    var onDelete: (URL) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onTerminalHere: (URL) -> Void

    @State private var hovering = false

    private var isExpanded: Bool { expanded.contains(node.url) }
    private var isSelected: Bool { selection.fileURL == node.url }

    var body: some View {
        HStack(spacing: 4) {
            // Disclosure chevron (folders only); files get matching indent.
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(VSCode.muted)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: node.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 16)
            Text(node.name)
                .font(.system(size: 13))
                .foregroundStyle(VSCode.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 8)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if node.isDirectory {
                if isExpanded { expanded.remove(node.url) } else { expanded.insert(node.url) }
            } else {
                onSelect(node.url)
            }
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if node.isDirectory {
            Button("New File…") { onNewFile(node.url) }
            Button("New Folder…") { onNewFolder(node.url) }
            Button("Open in Terminal") { onTerminalHere(node.url) }
            Divider()
        }
        Button("Rename…") { onRename(node.url, node.name) }
        if !node.isDirectory {
            Divider()
            Button("Move to Folder…") { onMove(node.url) }
            Button("Move Up") { onMoveInOrder(node.url, .up) }
                .disabled(!canMoveUp)
            Button("Move Down") { onMoveInOrder(node.url, .down) }
                .disabled(!canMoveDown)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Button("Delete", role: .destructive) { onDelete(node.url) }
    }

    private var rowBackground: some View {
        Group {
            if isSelected { VSCode.selectionBg }
            else if hovering { VSCode.hoverBg }
            else { Color.clear }
        }
    }

    private var iconColor: Color {
        if node.isDirectory { return Color(hex: 0xC0A36E) }       // folder amber, like VS Code
        if node.isMarkdown { return Color(hex: 0x6FB3D2) }         // markdown blue
        if node.isImage { return Color(hex: 0x9DB87A) }            // image green
        return VSCode.muted
    }
}

extension Notification.Name {
    static let openTerminalAt = Notification.Name("openTerminalAt")
}
#endif
