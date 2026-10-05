import SwiftUI

struct NoteEmbedView: View {
    @EnvironmentObject private var store: VaultStore
    let target: String
    let document: URL
    let root: URL
    let depth: Int
    var onOpenNote: ((String) -> Void)?
    @State private var url: URL?
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onOpenNote?(target) } label: { Label(target, systemImage: "doc.text") }
            if depth >= 2 { Text("Open the note to view deeper embeds.").font(.caption) }
            else if let text, let url {
                MarkdownPreview(markdown: text, resolveImage: { store.resolveImageURL($0, relativeTo: url) },
                    documentURL: url, vaultRootURL: root, onOpenNote: { nested in
                        Task {
                            let parts = MarkdownKnowledge.splitTarget(nested)
                            if let resolved = await store.resolveNote(nested, from: url) {
                                let target = MarkdownKnowledge.relativePath(resolved, to: root)
                                    + (parts.fragment.isEmpty ? "" : "#" + parts.fragment)
                                onOpenNote?(target)
                            }
                        }
                    }, embedDepth: depth + 1)
                    .frame(minHeight: 120, maxHeight: 350)
            } else if let error { Text(error).font(.caption).foregroundStyle(Theme.mutedInk) }
            else { ProgressView() }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: AppMetrics.cardRadius))
        .task(id: target) {
            guard depth < 2 else { return }
            do {
                guard let resolved = await store.resolveNote(target, from: document) else {
                    error = String(localized: "Unresolved link")
                    return
                }
                let content = try await VaultFileAccess.shared.readText(at: resolved)
                guard !Task.isCancelled else { return }
                url = resolved
                text = Self.fragment(MarkdownKnowledge.splitTarget(target).fragment, in: content)
            } catch { self.error = error.localizedDescription }
        }
    }

    static func fragment(_ anchor: String, in text: String) -> String {
        guard !anchor.isEmpty else { return text }
        let body = MarkdownKnowledge.body(text)
        let lines = body.components(separatedBy: "\n")
        if anchor.hasPrefix("^") {
            if let i = lines.firstIndex(where: { $0.hasSuffix(" " + anchor) || $0 == anchor }) {
                var start = i
                while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
                return lines[start...i].joined(separator: "\n").replacingOccurrences(of: " " + anchor, with: "")
            }
            return String(localized: "The referenced block was not found.")
        }
        let headings = MarkdownKnowledge.analyze(text, url: URL(fileURLWithPath: "/note.md")).headings
        guard let heading = headings.first(where: { MarkdownPreview.headingKey($0.title) == MarkdownPreview.headingKey(anchor) }) else {
            return String(localized: "The referenced heading was not found.")
        }
        let end = headings.first(where: { $0.line > heading.line && $0.level <= heading.level })?.line ?? lines.count
        return lines[heading.line..<end].joined(separator: "\n")
    }
}
