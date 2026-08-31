import SwiftUI

struct GeneratedNotePreview: View {
    @State private var draft: GeneratedNoteDraft

    let onSave: (GeneratedNoteDraft) -> Void
    let onCancel: () -> Void

    init(draft: GeneratedNoteDraft,
         onSave: @escaping (GeneratedNoteDraft) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Title", text: $draft.title)
                    TextField("Summary", text: $draft.summary, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Category", text: $draft.category)
                    TextField("Tags (comma separated)", text: tagsBinding)
                }

                Section("Body") {
                    TextEditor(text: $draft.content)
                        .frame(minHeight: 260)
                        .font(.system(.body, design: .monospaced))
                }

                if let sourceURL = draft.sourceURL {
                    Section("Source") {
                        Label(sourceURL.absoluteString,
                              systemImage: "link")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedInk)
                            .textSelection(.enabled)
                    }
                }

                Section("Original Clipboard") {
                    DisclosureGroup("View Original") {
                        Text(draft.originalText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Type: \(draft.contentKind.title)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                }
            }
            .navigationTitle("Confirm Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft) }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { draft.tags.joined(separator: ", ") },
            set: { value in
                draft.tags = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
