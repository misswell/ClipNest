import SwiftUI

@main
struct MarkdownVaultApp: App {
    @StateObject private var store: VaultStore
    @StateObject private var captureCoordinator: CaptureCoordinator
    @StateObject private var search: LocalSearchController

    init() {
        let store = VaultStore()
        _store = StateObject(wrappedValue: store)
        _captureCoordinator = StateObject(wrappedValue: CaptureCoordinator(store: store))
        _search = StateObject(wrappedValue: LocalSearchController())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.knowledge)
                .environmentObject(store.selection)
                .environmentObject(captureCoordinator)
                .environmentObject(search)
                .tint(Theme.accent)
                #if os(macOS)
                .modifier(SoftwareUpdatePresentation())
                #endif
                .task {
                    // The local model is loaded on demand and released under memory pressure
                    // or when the app goes to the background (China plan §26).
                    await LocalModelRuntime.shared.startObservingSystemPressure()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SoftwareUpdateCommands()
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
            CommandMenu("Notes") {
                Button("Workspaces") { store.showWorkspaces = true }
                Button("Command Palette") { store.showCommandPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Knowledge") { store.showKnowledge = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Open Daily Note") { store.openDailyNote() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Random Note") {
                    if let url = store.homeSnapshot.markdownFiles.randomElement() { store.selectedFileURL = url }
                }
            }
            CommandMenu("Capture") {
                Button("Quick Paste") {
                    NotificationCenter.default.post(name: .quickPasteCapture, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Import Image…") {
                    NotificationCenter.default.post(name: .importImageCapture, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
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
