import SwiftUI

/// The confirm-before-save screen (方案 §29).
///
/// It mirrors the `NoteFormatConfiguration` that produced the draft: a section the format
/// turned off is not shown as an empty field, it is not there at all. What the user sees is
/// what will be rendered into the vault.
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

    private var format: NoteFormatConfiguration { draft.format }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Title", text: $draft.title)
                    if format.includeSummary {
                        TextField("Summary", text: $draft.summary, axis: .vertical)
                            .lineLimit(2...4)
                    }
                    TextField("Category", text: $draft.category)
                    if format.includeTags {
                        TextField("Tags (comma separated)", text: tagsBinding)
                    }
                }

                if format.generatesBody {
                    Section("Body") {
                        TextEditor(text: $draft.content)
                            .frame(minHeight: 260)
                            .font(.system(.body, design: .monospaced))
                    }
                } else if !draft.images.isEmpty {
                    Section("Attachments") {
                        Label("\(draft.images.count)", systemImage: "photo.on.rectangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedInk)
                    }
                }

                if format.includeSourceURL, let sourceURL = draft.sourceURL {
                    Section("Source") {
                        Label(sourceURL.absoluteString,
                              systemImage: "link")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedInk)
                            .textSelection(.enabled)
                    }
                }

                if format.includeOriginalText {
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
                        .disabled(!isSaveable)
                }
            }
        }
    }

    /// A draft is saveable when it has a title and *something* to render — with the body
    /// sourced from the original text (or an image-only capture), an empty `content` field
    /// is no longer a failure (方案 §36⑬).
    private var isSaveable: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.images.isEmpty)
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
