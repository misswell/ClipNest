import SwiftUI

struct RootView: View {
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    @EnvironmentObject private var store: VaultStore
    @State private var appTab = 0
    @State private var showVaultImporter = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .tint(Theme.accent)
            .overlay(alignment: .top) {
                if captureCoordinator.showsStatusBanner {
                    CaptureProgressView()
                        .environmentObject(captureCoordinator)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: captureCoordinator.showsStatusBanner)
            .sheet(item: $captureCoordinator.pendingDraft) { draft in
                GeneratedNotePreview(
                    draft: draft,
                    onSave: { updated in
                        Task { await captureCoordinator.saveDraft(updated) }
                    },
                    onCancel: { captureCoordinator.cancelPendingDraft() }
                )
            }
            .alert(
                "Capture Failed",
                isPresented: Binding(
                    get: { captureCoordinator.errorMessage != nil },
                    set: { if !$0 { captureCoordinator.dismissError() } }
                )
            ) {
                Button("Retry") {
                    Task { await captureCoordinator.retry() }
                }
                Button("Save As-Is") {
                    Task { await captureCoordinator.saveRawClipboard() }
                }
                Button("Cancel", role: .cancel) {
                    captureCoordinator.dismissError()
                }
            } message: {
                Text(captureCoordinator.errorMessage ?? String(localized: "Unknown error"))
            }
            .task {
                await captureCoordinator.start()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await captureCoordinator.sceneDidBecomeActive() }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VSCodeLayout()
        #else
        TabView(selection: $appTab) {
            VaultView()
                .tabItem { Label("Vault", systemImage: "folder.fill") }
                .tag(0)
            DocumentTimelineView()
                .tabItem { Label("Timeline", systemImage: "clock") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        // Owned here rather than in VaultView: any tab can ask for the folder picker
        // (the sidebar, or the settings "Open Another Folder…" row), and a request must not
        // depend on the Vault tab already having been built.
        .fileImporter(isPresented: $showVaultImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { store.openVault(at: url) }
        }
        .onChange(of: store.openVaultRequested) { _, requested in
            guard requested else { return }
            store.openVaultRequested = false
            showVaultImporter = true
        }
        #endif
    }
}
