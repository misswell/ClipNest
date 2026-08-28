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
                Section("笔记") {
                    TextField("标题", text: $draft.title)
                    TextField("摘要", text: $draft.summary, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("分类", text: $draft.category)
                    TextField("标签（用逗号分隔）", text: tagsBinding)
                }

                Section("正文") {
                    TextEditor(text: $draft.content)
                        .frame(minHeight: 260)
                        .font(.system(.body, design: .monospaced))
                }

                if let sourceURL = draft.sourceURL {
                    Section("来源") {
                        Label(sourceURL.absoluteString,
                              systemImage: "link")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedInk)
                            .textSelection(.enabled)
                    }
                }

                Section("原始剪贴板") {
                    DisclosureGroup("查看原始内容") {
                        Text(draft.originalText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("类型：\(draft.contentKind.title)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                }
            }
            .navigationTitle("确认笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(draft) }
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
