import SwiftUI

@main
struct MarkdownVaultApp: App {
    @StateObject private var store: VaultStore
    @StateObject private var captureCoordinator: CaptureCoordinator

    init() {
        let store = VaultStore()
        _store = StateObject(wrappedValue: store)
        _captureCoordinator = StateObject(wrappedValue: CaptureCoordinator(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.selection)
                .environmentObject(captureCoordinator)
                .tint(Theme.accent)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Markdown File") { store.requestNewFile() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Open Vault Folder…") { store.requestOpenVault() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Quick Open…") {
                    NotificationCenter.default.post(name: .quickOpen, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command])
            }
            CommandMenu("Terminal") {
                Button("New Terminal") {
                    NotificationCenter.default.post(name: .newTerminal, object: nil)
                }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                Button("Toggle Terminal Panel") {
                    NotificationCenter.default.post(name: .toggleTerminal, object: nil)
                }
                .keyboardShortcut("`", modifiers: [.control])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Side Bar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
        }
        #endif
    }
}
