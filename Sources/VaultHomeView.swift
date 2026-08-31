import SwiftUI

/// A lightweight iPhone landing surface. It uses the already-built FileNode tree, so the
/// capture path does not need to scan note bodies just to render the home screen.
struct VaultHomeView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    #if os(iOS)
    @State private var showPhotoPicker = false
    #endif
    var onSelect: ((URL) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ClipNest")
                        .font(.largeTitle.bold())
                    Text("Copy something, open ClipNest, and it becomes a Markdown note.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedInk)
                }

                #if os(iOS)
                photoCaptureSection
                #endif
                inboxSection
                recentSection
                categoriesSection
            }
            .padding(22)
            // The Vault container owns the floating action button, including the compact
            // iPhone sidebar route. Keep the final rows clear of it on the home detail.
            .padding(.bottom, 88)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(store.vaultName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Photo capture remains a secondary card; clipboard capture is the primary floating
    /// action owned by the Vault container.
    #if os(iOS)
    private var photoCaptureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showPhotoPicker = true
            } label: {
                HStack(spacing: 8) {
                    if captureCoordinator.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Text("Capture Photo")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(captureCoordinator.isProcessing)
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker { image in
                    showPhotoPicker = false
                    guard let image else { return }
                    Task { await captureCoordinator.capturePhoto(image) }
                }
                .ignoresSafeArea()
            }

            Text("Use the floating Quick Paste button to capture the current clipboard content.")
                .font(.caption)
                .foregroundStyle(Theme.mutedInk)
        }
        .appCard()
    }
    #endif

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Inbox", systemImage: "tray.fill")
            if let url = store.homeSnapshot.inboxFile {
                noteButton(url)
            } else {
                Text("Unsorted content and AI failures are kept safe here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedInk)
            }
        }
        .appCard()
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Recent Notes", systemImage: "clock")
            let notes = store.recentMarkdownFiles(limit: 8)
            if notes.isEmpty {
                Text("No Markdown notes yet.")
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
            sectionTitle("Categories", systemImage: "folder.fill")
            let categories = store.categorySummaries()
            if categories.isEmpty {
                Text("Top-level folders you create show up here.")
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
