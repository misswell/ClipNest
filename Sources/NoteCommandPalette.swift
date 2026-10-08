import SwiftUI

enum NoteCommand: String, CaseIterable, Identifiable {
    case new = "New Note", daily = "Open Daily Note", unique = "Unique Note", random = "Random Note"
    case knowledge = "Knowledge", refresh = "Refresh Vault", quickOpen = "Quick Open…"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: return String(localized: "New Note")
        case .daily: return String(localized: "Open Daily Note")
        case .unique: return String(localized: "Unique Note")
        case .random: return String(localized: "Random Note")
        case .knowledge: return String(localized: "Knowledge")
        case .refresh: return String(localized: "Refresh Vault")
        case .quickOpen: return String(localized: "Quick Open…")
        }
    }
}

struct NoteCommandPalette: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var commands: [NoteCommand] {
        NoteCommand.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List(commands) { command in
                Button(command.title) { run(command); dismiss() }
                    .disabled(store.rootURL == nil && command != .knowledge)
            }
            .searchable(text: $query, prompt: "Search commands")
            .navigationTitle("Command Palette")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 420)
        #endif
    }
    private func run(_ command: NoteCommand) {
        switch command {
        case .new: store.requestNewFile()
        case .daily: store.openDailyNote()
        case .unique:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMddHHmmss"
            _ = store.openOrCreateNote(path: formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6))
        case .random: store.selectedFileURL = store.homeSnapshot.markdownFiles.randomElement()
        case .knowledge: store.showKnowledge = true
        case .refresh: store.refresh(); store.knowledge.refresh()
        case .quickOpen:
            #if os(macOS)
            NotificationCenter.default.post(name: .quickOpen, object: nil)
            #else
            store.showKnowledge = true
            #endif
        }
    }
}
