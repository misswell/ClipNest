import SwiftUI

struct NoteComposerView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var index: VaultKnowledgeIndex
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @Binding var text: String
    var onOpen: (URL) -> Void
    @State private var selected: URL?
    @State private var heading: NoteHeading?
    @State private var path = ""
    @State private var isMerging = false
    @State private var isBusy = false
    @State private var error: String?
    @State private var confirmMerge = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $isMerging) {
                    Text("Extract Section").tag(false)
                    Text("Merge Note").tag(true)
                }
                if isMerging {
                    Picker("Destination Note", selection: $selected) {
                        Text("Choose a note").tag(Optional<URL>.none)
                        ForEach(index.sortedNotes.filter { $0.url != url }, id: \.url) { note in
                            Text(note.url.deletingPathExtension().lastPathComponent).tag(Optional(note.url))
                        }
                    }
                    Text("The source note moves to Trash after a successful merge. Linked notes are updated. Duplicate headings must be renamed first.").font(.caption)
                } else {
                    Picker("Section", selection: Binding(get: { heading?.line ?? -1 }, set: { value in
                        heading = MarkdownKnowledge.analyze(text, url: url).headings.first { $0.line == value }
                    })) {
                        Text("Choose a section").tag(-1)
                        ForEach(MarkdownKnowledge.analyze(text, url: url).headings) { item in Text(item.title).tag(item.line) }
                    }
                    TextField("New note path", text: $path)
                    Text("The section and its subsections move into a new note. A link replaces the extracted content.").font(.caption)
                }
                if let error { Text(error).foregroundStyle(Theme.mutedInk) }
                if isBusy { ProgressView("Updating notes…") }
            }
            .navigationTitle("Compose Notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMerging ? "Merge" : "Extract") { if isMerging { confirmMerge = true } else { compose() } }
                        .disabled(isBusy || (isMerging ? selected == nil : heading == nil || path.isEmpty))
                }
            }
            .confirmationDialog("Merge this note into the destination?", isPresented: $confirmMerge, titleVisibility: .visible) {
                Button("Merge", role: .destructive) { compose() }
            }
            .interactiveDismissDisabled(isBusy)
            .task { index.ensureLoaded() }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    private func compose() {
        guard let root = store.rootURL else { return }
        let expected = text
        if isMerging, let selected {
            isBusy = true
            Task {
                do {
                    let mutation = try await Task.detached(priority: .userInitiated) {
                        try VaultNoteComposer.merge(source: url, destination: selected, root: root, expectedSource: expected)
                    }.value
                    guard store.rootURL == root else { dismiss(); return }
                    store.lastLinkMutation = mutation
                    store.lastDeletedURL = url
                    store.selectedFileURL = selected
                    store.refresh(); store.notifyFileChanges([url] + mutation.rewrittenFiles)
                    dismiss(); onOpen(selected)
                } catch { self.error = error.localizedDescription }
                isBusy = false
            }
        } else if let heading {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
                && !$0.contains(":") && !$0.contains("\\") && !$0.contains("[") && !$0.contains("]")
                && !$0.contains("|") && !$0.contains("#") }) else { error = String(localized: "Enter a relative note path inside this vault."); return }
            var destination = root.appendingPathComponent(path).standardizedFileURL
            if destination.pathExtension.isEmpty { destination.appendPathExtension("md") }
            let target = destination
            isBusy = true
            Task {
                do {
                    let updated = try await Task.detached(priority: .userInitiated) {
                        try VaultNoteComposer.extract(source: url, destination: target, root: root, text: expected, heading: heading)
                    }.value
                    guard store.rootURL == root else { dismiss(); return }
                    text = updated
                    store.refresh(); store.notifyFileChanges([url, target]); dismiss()
                } catch { self.error = error.localizedDescription }
                isBusy = false
            }
        }
    }
}
