import Foundation

struct GeneratedNote: Codable, Equatable {
    var title: String
    var summary: String
    var content: String
    var category: String
    var tags: [String]
    var sourceURL: URL?
}

/// Editable form used by the confirmation workflow. The original clipboard payload and
/// hash stay attached so saving a modified preview still produces a complete note and marks
/// the correct clipboard item as handled.
///
/// The capture's images and the note format that produced the draft travel with it (方案 §29):
/// the preview shows only the sections the format enables, and saving replays the same
/// attachment transaction an automatic save would have taken.
struct GeneratedNoteDraft: Identifiable, Equatable {
    let id: UUID
    var title: String
    var summary: String
    var content: String
    var category: String
    var tags: [String]
    var sourceURL: URL?
    let originalText: String
    let contentKind: ClipboardContentKind
    let sourceKind: CaptureSourceKind
    let clipboardHash: String
    let format: NoteFormatConfiguration
    let images: [CapturedImage]

    init(note: GeneratedNote,
         snapshot: ClipboardSnapshot,
         format: NoteFormatConfiguration = .default) {
        id = UUID()
        title = note.title
        summary = note.summary
        content = note.content
        category = note.category
        tags = note.tags
        sourceURL = note.sourceURL ?? snapshot.content.sourceURL
        originalText = snapshot.content.rawText
        contentKind = snapshot.content.kind
        sourceKind = snapshot.sourceKind
        clipboardHash = snapshot.hash
        self.format = format
        images = snapshot.images
    }

    /// The captured material this draft saves, unchanged from the capture itself.
    var captured: CapturedContent {
        CapturedContent(text: originalText,
                        sourceURL: sourceURL,
                        sourceKind: sourceKind,
                        images: images)
    }

    var note: GeneratedNote {
        GeneratedNote(title: title,
                      summary: summary,
                      content: content,
                      category: category,
                      tags: tags,
                      sourceURL: sourceURL)
    }

    var tagsText: String {
        get { tags.joined(separator: ", ") }
        set {
            tags = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}
