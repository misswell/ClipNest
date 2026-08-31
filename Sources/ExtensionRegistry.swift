#if os(macOS)
import SwiftUI

/// A catalog entry in the (curated) extension marketplace. These aren't dynamically loaded
/// plug-ins — they are built-in capabilities the user can install (enable) or uninstall.
struct AppExtension: Identifiable, Hashable {
    let id: String
    let name: String
    let publisher: String
    let summary: String
    let symbol: String
    let installs: String        // marketplace-style flavor text
    let hasPanel: Bool          // whether "Manage" opens an in-app panel
    var comingSoon: Bool = false
}

/// Tracks which marketplace extensions are installed. Persisted in UserDefaults.
final class ExtensionRegistry: ObservableObject {
    static let shared = ExtensionRegistry()
    private let key = "extensions.installed"

    @Published private(set) var installed: Set<String>

    private init() {
        installed = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    let catalog: [AppExtension] = [
        AppExtension(id: "wiki-llm", name: "Wiki (LLM)", publisher: "Tertiary Infotech",
                     summary: String(localized: "Turn your vault into an LLM-maintained wiki — ingest sources, auto-link [[pages]], query and lint with Claude Code."),
                     symbol: "books.vertical.fill", installs: String(localized: "Karpathy-style"), hasPanel: true),
        AppExtension(id: "github", name: "GitHub", publisher: "GitHub",
                     summary: String(localized: "Sign in with GitHub, then version your vault: init, commit, and push straight from the app via the gh CLI."),
                     symbol: "arrow.triangle.branch", installs: String(localized: "Source control"), hasPanel: true),
        AppExtension(id: "mermaid", name: String(localized: "Mermaid Diagrams"), publisher: String(localized: "Community"),
                     summary: String(localized: "Render ```mermaid fenced blocks as flowcharts and sequence diagrams in preview."),
                     symbol: "flowchart", installs: String(localized: "Preview"), hasPanel: false, comingSoon: true),
        AppExtension(id: "wordcount", name: String(localized: "Word Count"), publisher: String(localized: "Community"),
                     summary: String(localized: "Live word and character count for the current note in the status bar."),
                     symbol: "textformat.123", installs: String(localized: "Status bar"), hasPanel: false, comingSoon: true),
    ]

    func ext(_ id: String) -> AppExtension? { catalog.first { $0.id == id } }
    func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    func install(_ id: String) {
        installed.insert(id)
        persist()
    }
    func uninstall(_ id: String) {
        installed.remove(id)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(installed), forKey: key)
    }
}
#endif
