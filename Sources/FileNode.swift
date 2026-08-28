import Foundation

/// A node in the vault file tree. Directories carry `children`; files have `nil`.
struct FileNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    static let editableExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text", "csv"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg"]

    var ext: String { url.pathExtension.lowercased() }
    var isMarkdown: Bool { ["md", "markdown", "mdown"].contains(ext) }
    var isEditable: Bool { Self.editableExtensions.contains(ext) }
    var isImage: Bool { Self.imageExtensions.contains(ext) }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        if isMarkdown { return "doc.text.fill" }
        if isImage { return "photo.fill" }
        if ext == "pdf" { return "doc.richtext.fill" }
        return "doc.fill"
    }
}

struct FileTreeMoveAvailability {
    let up: Bool
    let down: Bool

    static let none = FileTreeMoveAvailability(up: false, down: false)
}

/// Computes move-menu state once for a tree level. Passing a map to each row keeps rendering
/// linear in the number of siblings instead of filtering the same array for every row.
func fileTreeMoveAvailabilities(for siblings: [FileNode]) -> [URL: FileTreeMoveAvailability] {
    let documents = siblings.filter { !$0.isDirectory }
    return documents.enumerated().reduce(into: [URL: FileTreeMoveAvailability]()) { result, item in
        result[item.element.url] = FileTreeMoveAvailability(
            up: item.offset > 0,
            down: item.offset + 1 < documents.count)
    }
}
