import SwiftUI

/// Timestamps the moment the Vault tab becomes visible, so the file list can ignore
/// the tab-switch tap that "passes through" onto a note row underneath the tab bar.
@MainActor
final class VaultTabTracker: ObservableObject {
    @Published var vaultTabActivatedAt = Date.distantPast
}

struct RootView: View {
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
    @StateObject private var vaultTabTracker = VaultTabTracker()
    @State private var appTab = 0
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
        .onChange(of: appTab) { _, newValue in
            if newValue == 0 { vaultTabTracker.vaultTabActivatedAt = Date() }
        }
        .environmentObject(vaultTabTracker)
        #endif
    }
}
