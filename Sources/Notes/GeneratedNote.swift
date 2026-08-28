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
    let clipboardHash: String

    init(note: GeneratedNote, snapshot: ClipboardSnapshot) {
        id = UUID()
        title = note.title
        summary = note.summary
        content = note.content
        category = note.category
        tags = note.tags
        sourceURL = note.sourceURL ?? snapshot.content.sourceURL
        originalText = snapshot.content.rawText
        contentKind = snapshot.content.kind
        clipboardHash = snapshot.hash
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
