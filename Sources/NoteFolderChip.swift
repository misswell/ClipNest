import SwiftUI

/// Remembers the folders a note has just been moved into, newest first.
///
/// Absolute paths rather than names: the re-file that matters after a paste is usually into a
/// *nested* folder — next to its siblings — and that choice is worth offering again exactly where
/// it was, not flattened to its last component.
enum RecentMoveFolders {
    private static let limit = 4

    /// Newline-separated absolute paths, newest first.
    static func paths(in raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func record(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        var stored = paths(in: UserDefaults.standard.string(
            forKey: ClipNestSettings.recentMoveFolders) ?? "")
        stored.removeAll { $0 == path }
        stored.insert(path, at: 0)
        UserDefaults.standard.set(stored.prefix(limit).joined(separator: "\n"),
                                  forKey: ClipNestSettings.recentMoveFolders)
    }
}

/// The open document's folder, as a pill that moves the note in one tap.
///
/// Every detail surface carries one. `VaultStore` never records a note's category anywhere but in
/// the directory it was written to, so the folder pill is the only place a mis-filed capture can
/// be corrected — which is why it appears on the page itself instead of only in an overflow menu.
struct NoteFolderChip: View {
    @EnvironmentObject private var store: VaultStore

    let fileURL: URL
    /// True for a few seconds after a capture opens its note: the pill takes the brand colour and
    /// states what it is for, then relaxes back into a plain breadcrumb.
    var emphasised = false

    @State private var browseAll: MoveDocumentTarget?
    @State private var isMoving = false
    /// Read as a view property (not through `RecentMoveFolders`) so a move re-renders the list.
    @AppStorage(ClipNestSettings.recentMoveFolders) private var recentPathsRaw = ""

    private struct Destination: Identifiable {
        let url: URL
        let name: String
        let isCurrent: Bool
        var id: String { url.path }
    }

    private var parentDirectory: URL { fileURL.deletingLastPathComponent().standardizedFileURL }
    private var rootDirectory: URL? { store.rootURL?.standardizedFileURL }

    var body: some View {
        HStack(spacing: 8) {
            folderMenu
            if emphasised {
                Text(verbatim: hintTitle)
                    .font(.caption)
                    .foregroundStyle(Theme.mutedInk)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: emphasised)
        .sheet(item: $browseAll) { target in
            MoveDocumentView(fileURL: target.url)
        }
    }

    private var folderMenu: some View {
        Menu {
            ForEach(destinations) { destination in
                Button {
                    move(to: destination.url)
                } label: {
                    Label(destination.name,
                          systemImage: destination.isCurrent ? "checkmark" : "folder")
                }
                .disabled(destination.isCurrent || isMoving)
            }

            Divider()

            Button {
                browseAll = MoveDocumentTarget(url: fileURL)
            } label: {
                Label("All Folders…", systemImage: "ellipsis.circle")
            }
            .disabled(isMoving)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isMoving ? "arrow.triangle.2.circlepath" : "folder.fill")
                    .font(.system(size: 10))
                Text(currentFolderName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(pillBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(pillBorder, lineWidth: emphasised ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .accessibilityLabel(Text("Move to Folder"))
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
    }

    // MARK: - Destinations

    /// The current folder first (so the pill's own state is legible in the list), then the
    /// top-level folders the classifier writes to, then the recent ones — nested ones included,
    /// which is what makes a repeated re-file of the same batch cheap.
    private var destinations: [Destination] {
        guard let root = rootDirectory else { return [] }
        var seen = Set<String>()
        var result: [Destination] = []

        func add(_ directory: URL, isCurrent: Bool = false) {
            let url = directory.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard seen.insert(url.path).inserted,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            result.append(Destination(url: url,
                                      name: displayName(for: url, root: root),
                                      isCurrent: isCurrent))
        }

        add(parentDirectory, isCurrent: true)
        for category in store.topLevelCategories() { add(root.appendingPathComponent(category)) }
        for path in RecentMoveFolders.paths(in: recentPathsRaw) {
            add(URL(fileURLWithPath: path))
        }
        return result
    }

    private var currentFolderName: String {
        guard let root = rootDirectory else { return store.vaultName }
        return displayName(for: parentDirectory, root: root)
    }

    /// Vault-root shows the vault's name, a top-level folder its own name, and a nested folder its
    /// path under the root — "Projects / 2026" instead of a bare "2026" that could be anywhere.
    private func displayName(for directory: URL, root: URL) -> String {
        if directory == root { return store.vaultName }
        let rootPath = root.path
        guard directory.path.hasPrefix(rootPath + "/") else { return directory.lastPathComponent }
        return directory.path
            .dropFirst(rootPath.count + 1)
            .split(separator: "/")
            .joined(separator: " / ")
    }

    // MARK: - Actions

    private func move(to directory: URL) {
        guard !isMoving, directory.standardizedFileURL != parentDirectory else { return }
        isMoving = true
        Task {
            let moved = await store.moveWithLinks(fileURL, to: directory)
            isMoving = false
            // A refusal leaves the reason in `store.operationError`, which RootView already
            // surfaces as an app-wide alert.
            guard moved != nil else { return }
            RecentMoveFolders.record(directory)
        }
    }

    // MARK: - Palette

    /// The line that explains the pill while a capture is still fresh — phrased per platform,
    /// because a finger taps and a mouse clicks.
    #if os(macOS)
    private var hintTitle: String { String(localized: "Move to another folder") }
    #else
    private var hintTitle: String { String(localized: "Tap to change folder") }
    #endif

    #if os(macOS)
    private var foreground: Color { emphasised ? VSCode.activeIcon : VSCode.fg }
    private var pillBackground: Color { emphasised ? VSCode.accent.opacity(0.32) : VSCode.hoverBg }
    private var pillBorder: Color { emphasised ? VSCode.accent : VSCode.border }
    #else
    private var foreground: Color { emphasised ? Theme.primary : Theme.ink }
    private var pillBackground: Color { emphasised ? Theme.primary.opacity(0.12) : Theme.surface }
    private var pillBorder: Color { emphasised ? Theme.primary : Theme.hairline }
    #endif
}
