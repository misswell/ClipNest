import SwiftUI

/// A lightweight iPhone landing surface. It uses the already-built FileNode tree, so the
/// capture path does not need to scan note bodies just to render the home screen.
struct VaultHomeView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    @Environment(\.horizontalSizeClass) private var hSize
    #if os(iOS)
    @State private var showPhotoPicker = false
    #endif
    var onSelect: ((URL) -> Void)? = nil

    private var horizontalPadding: CGFloat {
        AppMetrics.screenHorizontal(for: hSize)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
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
                if isLoadingHomeSnapshot {
                    loadingCard
                } else {
                    inboxSection
                    recentSection
                    categoriesSection
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, AppMetrics.screenTop)
            .padding(.bottom, AppMetrics.sectionSpacing)
            .frame(maxWidth: AppMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        #if os(iOS)
        // Rows must not be tappable through the floating tab bar.
        .bottomTabBarExclusion()
        #endif
        .navigationTitle(store.vaultName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Photo capture remains a secondary card; clipboard capture is the primary floating
    /// action owned by the Vault container.
    #if os(iOS)
    private var photoCaptureSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.rowSpacing) {
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

    /// Shown while the first home snapshot is being built, so the page never flashes
    /// its "no data" placeholders before real content arrives.
    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .appCard()
    }

    private var isLoadingHomeSnapshot: Bool {
        // Keep an existing snapshot visible during a refresh, but do not present empty-state
        // cards while the first tree/metadata pass is still in flight.
        !store.didRestoreVault
            || (store.rootURL != nil
                && store.isHomeSnapshotLoading
                && store.homeSnapshot == .empty)
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.rowSpacing) {
            AppSectionHeader(title: "Inbox", systemImage: "tray.fill")
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
        VStack(alignment: .leading, spacing: AppMetrics.rowSpacing) {
            AppSectionHeader(title: "Recent Notes", systemImage: "clock")
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
        VStack(alignment: .leading, spacing: AppMetrics.rowSpacing) {
            AppSectionHeader(title: "Categories", systemImage: "folder.fill")
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
                        .frame(minHeight: AppMetrics.controlHitSize)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(category.count == 0)
                }
            }
        }
        .appCard()
    }

    private func noteButton(_ url: URL) -> some View {
        Button {
            select(url)
        } label: {
            HStack(spacing: 10) {
                AppRowIcon(systemImage: "doc.text")
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedInk)
            }
            .frame(minHeight: AppMetrics.controlHitSize)
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
