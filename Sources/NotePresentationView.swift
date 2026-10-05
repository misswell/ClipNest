import SwiftUI

enum NoteSlides {
    static func split(_ markdown: String) -> [String] {
        let content = MarkdownKnowledge.body(markdown)
        let mask = MarkdownKnowledge.proseMask(content).components(separatedBy: "\n")
        let lines = content.components(separatedBy: "\n")
        var slides: [String] = []
        var start = 0
        for i in lines.indices where mask[i] == "---" {
            guard i > 0, i + 1 < lines.count, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            slides.append(lines[start..<i].joined(separator: "\n")); start = i + 1
        }
        slides.append(lines[start...].joined(separator: "\n"))
        return slides
    }
}

struct NotePresentationView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let text: String
    let url: URL
    @State private var slide = 0
    private var slides: [String] { NoteSlides.split(text) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(AppMetrics.screenHorizontal)
            MarkdownPreview(markdown: slides[min(slide, slides.count - 1)],
                resolveImage: { store.resolveImageURL($0, relativeTo: url) }, documentURL: url, vaultRootURL: store.rootURL)
                .id(slide)
            HStack {
                Button { slide = max(0, slide - 1) } label: { Label("Previous Slide", systemImage: "chevron.left") }
                    .disabled(slide == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                Text("\(slide + 1) / \(slides.count)").monospacedDigit()
                Spacer()
                Button { slide = min(slides.count - 1, slide + 1) } label: { Label("Next Slide", systemImage: "chevron.right") }
                    .disabled(slide == slides.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
            }.padding(AppMetrics.screenHorizontal)
        }.background(Theme.background)
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
}

struct NoteCalloutView: View {
    let text: AttributedString
    @State private var expanded = true
    var body: some View {
        let raw = String(text.characters)
        if let marker = MarkdownKnowledge.matches("^\\[!([A-Za-z]+)\\]([+-]?)([^\\n]*)", in: raw).first {
            let ns = raw as NSString
            let type = ns.substring(with: marker.range(at: 1)).capitalized
            let title = ns.substring(with: marker.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let content = ns.substring(from: NSMaxRange(marker.range)).trimmingCharacters(in: .newlines)
            VStack(alignment: .leading, spacing: 8) {
                if marker.range(at: 2).length > 0 {
                    DisclosureGroup(isExpanded: $expanded) { Text(MarkdownKnowledge.renderInline(content)) } label: {
                        Label(title.isEmpty ? type : title, systemImage: "info.circle.fill").font(.headline)
                    }
                } else {
                    Label(title.isEmpty ? type : title, systemImage: "info.circle.fill").font(.headline)
                    Text(MarkdownKnowledge.renderInline(content))
                }
            }
            .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: AppMetrics.cardRadius))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
            .onAppear { expanded = ns.substring(with: marker.range(at: 2)) != "-" }
        } else {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4)
                Text(text).foregroundStyle(Theme.mutedInk).italic()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
    }
}
