#if os(macOS)
import SwiftUI

/// The desktop start page, shown in the editor area while no document is open. It carries
/// the same content as the iPhone's Vault Home — Inbox, Recent Notes, Categories — plus
/// quick actions and the shell's keyboard shortcuts, styled with the desktop chrome tokens.
struct HomeWelcomeView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                quickActions
                if storeDidLoad {
                    if store.homeSnapshot == .empty && store.isHomeSnapshotLoading {
                        loadingCard
                    } else {
                        homeColumns
                    }
                }
                shortcutFooter
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(VSCode.editorBg)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ClipNest")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.primary, Theme.secondary],
                                   startPoint: .leading, endPoint: .trailing)
                )
            Text(store.rootURL == nil
                 ? "Open a folder of Markdown files to get started."
                 : "Copy something, and it becomes a Markdown note in “\(store.vaultName)”.")
                .font(.system(size: 13))
                .foregroundStyle(VSCode.muted)
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            actionChip("New Note", systemImage: "square.and.pencil") {
                store.requestNewFile()
            }
            actionChip("Quick Paste", systemImage: "doc.on.clipboard") {
                NotificationCenter.default.post(name: .quickPasteCapture, object: nil)
            }
            actionChip("Import Image", systemImage: "photo.on.rectangle") {
                NotificationCenter.default.post(name: .importImageCapture, object: nil)
            }
            if store.rootURL == nil {
                actionChip("Open Vault…", systemImage: "folder") {
                    store.requestOpenVault()
                }
                actionChip("Open Sample Vault", systemImage: "sparkles") {
                    store.openSampleVault()
                }
            }
        }
    }

    private func actionChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VSCode.fg)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(VSCode.hoverBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VSCode.border))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Home content

    private var homeColumns: some View {
        HStack(alignment: .top, spacing: 16) {
            homeCard(title: "Recent Notes", systemImage: "clock") {
                recentRows
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16) {
                homeCard(title: "Inbox", systemImage: "tray.fill") {
                    inboxRow
                }
                homeCard(title: "Categories", systemImage: "folder.fill") {
                    categoryRows
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func homeCard<Content: View>(title: String,
                                         systemImage: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VSCode.muted)
                    .tracking(0.5)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VSCode.border))
    }

    @ViewBuilder
    private var inboxRow: some View {
        if let url = store.homeSnapshot.inboxFile {
            homeRow(title: url.deletingPathExtension().lastPathComponent,
                    subtitle: "Inbox", date: nil)
        } else {
            cardHint("Unsorted content and AI failures are kept safe here.")
        }
    }

    @ViewBuilder
    private var recentRows: some View {
        let items = Array(store.homeSnapshot.timelineItems.prefix(6))
        if items.isEmpty {
            cardHint("No Markdown notes yet.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    homeRow(title: item.url.deletingPathExtension().lastPathComponent,
                            subtitle: relativePath(for: item.url),
                            date: item.date)
                    if item.id != items.last?.id {
                        Divider().overlay(VSCode.border.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, -8)
        }
    }

    @ViewBuilder
    private var categoryRows: some View {
        let categories = store.categorySummaries()
        if categories.isEmpty {
            cardHint("Top-level folders you create show up here.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(categories) { category in
                    Button {
                        if let url = store.firstMarkdownFile(inCategory: category.name) {
                            store.selectedFileURL = url
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: 0xC0A36E))
                                .frame(width: 16)
                            Text(category.name)
                                .font(.system(size: 12))
                                .foregroundStyle(VSCode.fg)
                                .lineLimit(1)
                            Spacer()
                            Text("\(category.count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(VSCode.muted)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(VSCode.hoverBg, in: Capsule())
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(category.count == 0)
                }
            }
            .padding(.horizontal, -8)
        }
    }

    private func homeRow(title: String, subtitle: String, date: Date?) -> some View {
        Button {
            store.selectedFileURL = currentRowURL(title: title, subtitle: subtitle)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x6FB3D2))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(VSCode.fg)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(VSCode.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let date {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .foregroundStyle(VSCode.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `homeRow` is shared by the Inbox card (which only knows the file URL) and the Recent
    /// list (which has the item in hand); both resolve to "select this note", so recover the
    /// URL from the snapshot instead of threading a second closure through the cards.
    private func currentRowURL(title: String, subtitle: String) -> URL? {
        if subtitle == "Inbox" { return store.homeSnapshot.inboxFile }
        return store.homeSnapshot.markdownFiles.first {
            $0.deletingPathExtension().lastPathComponent == title
        }
    }

    private func cardHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(VSCode.muted)
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(VSCode.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VSCode.border))
    }

    // MARK: - Footer

    private var shortcutFooter: some View {
        HStack(spacing: 18) {
            shortcut("Quick Open", "⌘P")
            shortcut("Toggle Side Bar", "⌘B")
            shortcut("Toggle Terminal", "⌃`")
            shortcut("Quick Paste", "⌘⇧V")
        }
        .padding(.top, 4)
    }

    private func shortcut(_ name: String, _ keys: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 11)).foregroundStyle(VSCode.muted)
            Text(keys)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VSCode.fg)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(VSCode.hoverBg, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Helpers

    /// Keep an existing snapshot visible during a refresh, but do not present "no data"
    /// cards before the first tree/metadata pass has finished (same rule as the iPhone home).
    private var storeDidLoad: Bool {
        store.didRestoreVault || store.rootURL == nil
    }

    private func relativePath(for url: URL) -> String {
        guard let root = store.rootURL else { return url.lastPathComponent }
        return url.deletingLastPathComponent().path
            .replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
#endif
