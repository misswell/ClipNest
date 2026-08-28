import SwiftUI

struct RootView: View {
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator
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
                "整理失败",
                isPresented: Binding(
                    get: { captureCoordinator.errorMessage != nil },
                    set: { if !$0 { captureCoordinator.dismissError() } }
                )
            ) {
                Button("重试") {
                    Task { await captureCoordinator.retry() }
                }
                Button("直接保存") {
                    Task { await captureCoordinator.saveRawClipboard() }
                }
                Button("取消", role: .cancel) {
                    captureCoordinator.dismissError()
                }
            } message: {
                Text(captureCoordinator.errorMessage ?? "未知错误")
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
        TabView {
            VaultView()
                .tabItem { Label("Vault", systemImage: "folder.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        #endif
    }
}
