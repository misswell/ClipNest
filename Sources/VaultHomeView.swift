import SwiftUI

/// A lightweight iPhone landing surface. It uses the already-built FileNode tree, so the
/// capture path does not need to scan note bodies just to render the home screen.
struct VaultHomeView: View {
    @EnvironmentObject private var store: VaultStore
    var onSelect: ((URL) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ClipNest")
                        .font(.largeTitle.bold())
                    Text("复制内容，打开 ClipNest，自动变成 Markdown 笔记。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedInk)
                }

                inboxSection
                recentSection
                categoriesSection
            }
            .padding(22)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(store.vaultName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Inbox", systemImage: "tray.fill")
            if let url = store.homeSnapshot.inboxFile {
                noteButton(url)
            } else {
                Text("未分类或 AI 失败的内容会安全保存到这里。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedInk)
            }
        }
        .appCard()
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("最近笔记", systemImage: "clock")
            let notes = store.recentMarkdownFiles(limit: 8)
            if notes.isEmpty {
                Text("还没有 Markdown 笔记。")
                    .foregroundStyle(Theme.mutedInk)
            } else {
                ForEach(notes, id: \.self) { url in
                    noteButton(url)
                    if url != notes.last { Divider() }
                }
            }
        }
        .appCard()
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("分类", systemImage: "folder.fill")
            let categories = store.categorySummaries()
            if categories.isEmpty {
                Text("创建的一级文件夹会显示在这里。")
                    .foregroundStyle(Theme.mutedInk)
            } else {
                ForEach(categories) { category in
                    Button {
                        if let url = store.firstMarkdownFile(inCategory: category.name) {
                            select(url)
                        }
                    } label: {
                        HStack {
                            Label(category.name, systemImage: "folder")
                            Spacer()
                            Text("\(category.count)")
                                .foregroundStyle(Theme.mutedInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(category.count == 0)
                }
            }
        }
        .appCard()
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(Theme.ink)
    }

    private func noteButton(_ url: URL) -> some View {
        Button {
            select(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.accent)
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ url: URL) {
        if let onSelect {
            onSelect(url)
        } else {
            store.selectedFileURL = url
        }
    }
}
