import SwiftUI

/// The NOTE FORMAT settings section (方案 §3, §4, §23, §25).
///
/// One configuration object governs the online provider, the on-device model and the Markdown
/// renderer, so this page never keeps derived copies — every change re-derives the preset,
/// saves the whole object, and the capture pipeline picks it up on the next capture.
///
/// The first layer stays deliberately simple (方案 §4): a preset picker, plain toggles for the
/// sections a note can have, one style picker and a preview. The prompt language never
/// surfaces here.
struct NoteFormatSettingsSection: View {
    @State private var configuration = NoteFormatConfigurationStore.load()

    var body: some View {
        Picker(selection: presetBinding) {
            ForEach(NoteFormatPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        } label: {
            Label("Format", systemImage: "doc.badge.gearshape")
        }
        .padding(.vertical, AppMetrics.rowVertical)
        Text(configuration.resolvedPreset.explanation)
            .font(.caption)
            .foregroundStyle(Theme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, AppMetrics.rowVertical)

        subHeader("CONTENT")
        toggleRow("Title", systemImage: "heading", keyPath: \.includeTitle)
        toggleRow("Summary", systemImage: "text.alignleft", keyPath: \.includeSummary)
        toggleRow("Organized Body (AI)", systemImage: "sparkles", keyPath: \.includeGeneratedBody)
        toggleRow("Original Text", systemImage: "doc.plaintext", keyPath: \.includeOriginalText)
        toggleRow("Keep Original Images", systemImage: "photo", keyPath: \.includeOriginalImage)
        Text("Images are always read for text recognition — this only decides whether the original picture is also saved into the vault.")
            .font(.caption)
            .foregroundStyle(Theme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, AppMetrics.rowVertical)

        subHeader("METADATA")
        toggleRow("Tags", systemImage: "tag", keyPath: \.includeTags)
        toggleRow("Frontmatter", systemImage: "macwindow.on.rectangle", keyPath: \.includeFrontmatter)
        toggleRow("Source URL", systemImage: "link", keyPath: \.includeSourceURL)

        subHeader("STYLE")
        Picker(selection: bodyStyleBinding) {
            ForEach(NoteBodyStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        } label: {
            Label("Writing Style", systemImage: "paintbrush")
        }
        .padding(.vertical, AppMetrics.rowVertical)
        Text(configuration.bodyStyle.explanation)
            .font(.caption)
            .foregroundStyle(Theme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
        if configuration.bodyStyle == .custom {
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Instruction")
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                TextEditor(text: customInstructionBinding)
                    .frame(minHeight: 72)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("\(configuration.trimmedCustomInstruction.count)/\(NoteFormatConfiguration.maximumInstructionCharacters)")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedInk)
                Text("Applies to both the on-device and the online model. The on-device model reads only the first \(NoteFormatConfiguration.maximumLocalInstructionCharacters) characters.")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, AppMetrics.rowVertical)
        }
        Text("Style only shapes the prose. The JSON output contract, classification and fact preservation are never changed by it.")
            .font(.caption)
            .foregroundStyle(Theme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, AppMetrics.rowVertical)

        subHeader("PREVIEW")
        DisclosureGroup {
            ScrollView {
                Text(previewMarkdown)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } label: {
            Label("What the note will look like", systemImage: "eye")
                .font(.callout)
        }
        .padding(.vertical, AppMetrics.rowVertical)
    }

    // MARK: - Rows

    private func subHeader(_ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mutedInk)
                .padding(.top, AppMetrics.rowVertical)
        }
    }

    private func toggleRow(_ titleKey: LocalizedStringKey,
                           systemImage: String,
                           keyPath: WritableKeyPath<NoteFormatConfiguration, Bool>) -> some View {
        Toggle(isOn: boolBinding(keyPath)) {
            Label(titleKey, systemImage: systemImage)
        }
        .padding(.vertical, AppMetrics.rowVertical)
    }

    // MARK: - Bindings

    private var presetBinding: Binding<NoteFormatPreset> {
        Binding(
            get: { configuration.resolvedPreset },
            set: { applyPreset($0) }
        )
    }

    /// The style picker owns body generation (方案 §12): 「保持原文」 asks no model for a body,
    /// every other style turns the organized body on.
    private var bodyStyleBinding: Binding<NoteBodyStyle> {
        Binding(
            get: { configuration.bodyStyle },
            set: { style in
                update { configuration in
                    configuration.bodyStyle = style
                    configuration.includeGeneratedBody = style != .original
                }
            }
        )
    }

    private var customInstructionBinding: Binding<String> {
        Binding(
            get: { configuration.customInstruction },
            set: { newValue in
                update { configuration in
                    configuration.customInstruction = newValue
                }
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<NoteFormatConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { value in
                update { configuration in
                    configuration[keyPath: keyPath] = value
                    // Keep the style and the body toggle telling the same story: turning the
                    // organized body off reverts to keeping the original text.
                    if keyPath == \.includeGeneratedBody {
                        configuration.bodyStyle = value
                            ? (configuration.bodyStyle == .original ? .knowledge : configuration.bodyStyle)
                            : .original
                    }
                }
            }
        )
    }

    // MARK: - Persistence

    /// Applies a change and persists it. The preset label always re-derives from the value
    /// (方案 §24), so hand-tuned toggles honestly read as Custom.
    private func update(_ transform: (inout NoteFormatConfiguration) -> Void) {
        var updated = configuration
        transform(&updated)
        updated.preset = updated.resolvedPreset
        configuration = updated
        NoteFormatConfigurationStore.save(updated)
    }

    private func applyPreset(_ preset: NoteFormatPreset) {
        update { configuration in
            configuration = configuration.applyingPreset(preset)
        }
    }

    // MARK: - Preview (方案 §25)

    /// Fixed sample material. The preview never calls any model — it renders the structure
    /// template with placeholders so the user sees exactly what their configuration builds.
    private static let sampleContent = ClipboardContent(text: """
    iOS Vision 可以在设备端进行 OCR，无需联网。
    实测在 iPhone 15 Pro 上，一张 A4 文档大约 0.4 秒完成识别。
    """)!

    private static let sampleNote = GeneratedNote(
        title: "iOS Vision 本地 OCR",
        summary: "用 Vision 在设备端识别图片文字，约 0.4 秒完成。",
        content: "## 要点\n\n- VNRecognizeTextRequest 做本地 OCR\n- iPhone 15 Pro 实测约 0.4 秒\n- 全程不联网",
        category: "Inbox",
        tags: ["iOS", "OCR"],
        sourceURL: URL(string: "https://example.com/vision-ocr"))

    private static let sampleAttachments = [
        SavedAttachment(url: URL(fileURLWithPath: "/preview/sample.jpg"),
                        relativePath: "Attachments/2026-09-25-sample.jpg")
    ]

    private var previewMarkdown: String {
        MarkdownNoteBuilder.make(note: Self.sampleNote,
                                 originalContent: Self.sampleContent,
                                 format: configuration,
                                 attachments: configuration.includeOriginalImage
                                    ? Self.sampleAttachments
                                    : [],
                                 date: Date(timeIntervalSince1970: 0))
    }
}
