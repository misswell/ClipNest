import SwiftUI

/// Renders parsed markdown blocks as native SwiftUI — Bear-style images and Notion-style tables.
struct MarkdownPreview: View {
    let markdown: String
    /// Resolve an image reference (`src`) to an on-disk URL relative to the current file.
    var resolveImage: (String) -> URL?
    /// Optional file/vault context. When supplied, image lookup runs off the main actor,
    /// including the Obsidian-style whole-vault fallback search.
    var documentURL: URL? = nil
    var vaultRootURL: URL? = nil
    /// Called with the document-wide checkbox index when a checklist box is tapped
    /// (Obsidian-style live toggling). When nil, checkboxes are read-only.
    var onToggleCheckbox: ((Int) -> Void)? = nil

    @State private var renderItems: [MarkdownRenderItem] = []
    @State private var isParsing = true
    @State private var renderRequestGate = PreviewRequestGate()

    var body: some View {
        Group {
            if isParsing {
                ProgressView("Rendering preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(renderItems) { item in
                            view(for: item.block, checkboxStart: item.checkboxStart)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
        }
        .background(Theme.background)
        .task(id: markdown) {
            let renderRequest = renderRequestGate.begin()
            isParsing = true
            renderItems = []
            let source = markdown
            let rendered = await Task.detached(priority: .utility) {
                MarkdownPreviewRenderer.render(source)
            }.value
            // A navigation transition can cancel the SwiftUI task after the detached parser
            // has started. Apply a still-current result even then; only a newer render request
            // is allowed to leave this view in a loading state.
            guard renderRequestGate.accepts(renderRequest) else { return }
            renderItems = rendered
            isParsing = false
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownRenderBlock, checkboxStart: Int = 0) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text).font(headingFont(level)).bold().padding(.top, level <= 2 ? 6 : 2)

        case let .paragraph(text):
            Text(text)

        case let .bulleted(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.accent)
                        Text(items[idx])
                    }
                }
            }

        case let .numbered(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).").foregroundStyle(Theme.accent).monospacedDigit()
                        Text(items[idx])
                    }
                }
            }

        case let .checklist(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { idx in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            onToggleCheckbox?(checkboxStart + idx)
                        } label: {
                            Image(systemName: items[idx].done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(items[idx].done ? Theme.accent : Theme.mutedInk)
                        }
                        .buttonStyle(.plain)
                        .disabled(onToggleCheckbox == nil)
                        Text(items[idx].text)
                            .strikethrough(items[idx].done, color: Theme.mutedInk)
                            .foregroundStyle(items[idx].done ? Theme.mutedInk : Theme.ink)
                    }
                }
            }

        case let .code(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case let .quote(text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4)
                Text(text).foregroundStyle(Theme.mutedInk).italic()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

        case let .table(headers, rows):
            TableBlock(headers: headers, rows: rows)

        case let .image(alt, src):
            imageView(alt: alt, src: src)

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func imageView(alt: String, src: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if src.hasPrefix("http"), let url = URL(string: src) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFit()
                    } else if phase.error != nil {
                        imagePlaceholder(src)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if vaultRootURL != nil {
                // The fallback filename search can walk a large vault. Keep it out of
                // SwiftUI body evaluation and let the image row resolve it asynchronously.
                LocalMarkdownImageView(source: src,
                                       documentURL: documentURL,
                                       vaultRootURL: vaultRootURL)
            } else if let url = resolveImage(src) {
                // Preserve the lightweight standalone-preview behavior when no vault
                // context is available.
                LocalMarkdownImageView(url: url, source: src)
            } else {
                imagePlaceholder(src)
            }
            if !alt.isEmpty, alt != src {
                Text(alt).font(.caption).foregroundStyle(Theme.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imagePlaceholder(_ src: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").foregroundStyle(Theme.mutedInk)
            Text("Missing image: \(src)").font(.caption).foregroundStyle(Theme.mutedInk)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        case 4: return .title3
        case 5: return .headline
        default: return .subheadline
        }
    }

}

/// The preview's expensive work is completed once per source revision, off the main actor.
/// Keeping attributed strings in the render model prevents SwiftUI body recomputation from
/// reparsing every visible line during image loading, scrolling, or checkbox updates.
private struct MarkdownRenderItem: Identifiable, Sendable {
    let id: Int
    let block: MarkdownRenderBlock
    let checkboxStart: Int
}

private enum MarkdownRenderBlock: Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case bulleted([AttributedString])
    case numbered([AttributedString])
    case checklist([MarkdownRenderChecklistItem])
    case code(language: String, code: String)
    case quote(AttributedString)
    case table(headers: [String], rows: [[String]])
    case image(alt: String, src: String)
    case rule
}

private struct MarkdownRenderChecklistItem: Sendable {
    let done: Bool
    let text: AttributedString
}

private enum MarkdownPreviewRenderer {
    static func render(_ markdown: String) -> [MarkdownRenderItem] {
        let blocks = MarkdownParser.parse(markdown)
        var result: [MarkdownRenderItem] = []
        result.reserveCapacity(blocks.count)

        var checkboxStart = 0
        for (index, block) in blocks.enumerated() {
            let rendered: MarkdownRenderBlock
            switch block {
            case let .heading(level, text):
                rendered = .heading(level: level, text: inline(text))
            case let .paragraph(text):
                rendered = .paragraph(inline(text))
            case let .bulleted(items):
                rendered = .bulleted(items.map(inline))
            case let .numbered(items):
                rendered = .numbered(items.map(inline))
            case let .checklist(items):
                rendered = .checklist(items.map {
                    MarkdownRenderChecklistItem(done: $0.done, text: inline($0.text))
                })
            case let .code(language, code):
                rendered = .code(language: language, code: code)
            case let .quote(text):
                rendered = .quote(inline(text))
            case let .table(headers, rows):
                rendered = .table(headers: headers, rows: rows)
            case let .image(alt, src):
                rendered = .image(alt: alt, src: src)
            case .rule:
                rendered = .rule
            }

            result.append(MarkdownRenderItem(id: index,
                                             block: rendered,
                                             checkboxStart: checkboxStart))
            if case let .checklist(items) = block {
                checkboxStart += items.count
            }
        }
        return result
    }

    /// Render inline markdown (bold/italic/links/code) per line. This runs in the detached
    /// renderer, so the main actor only receives ready-to-display attributed strings.
    private static func inline(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = AttributedString()
        for (index, raw) in lines.enumerated() {
            // Strip Obsidian wiki-link brackets for readability: [[Note]] -> Note
            let line = raw.replacingOccurrences(of: "[[", with: "")
                .replacingOccurrences(of: "]]", with: "")
            let attributed = (try? AttributedString(markdown: line, options: options))
                ?? AttributedString(line)
            result.append(attributed)
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }
}

/// Resolves and reads local attachments away from the main actor so an image-heavy note
/// does not stall the transition into its detail view.
private struct LocalMarkdownImageView: View {
    let url: URL?
    let source: String
    let documentURL: URL?
    let vaultRootURL: URL?

    @State private var image: Image?
    @State private var didFinishLoading = false
    @State private var loadRequestGate = PreviewRequestGate()

    init(url: URL? = nil,
         source: String,
         documentURL: URL? = nil,
         vaultRootURL: URL? = nil) {
        self.url = url
        self.source = source
        self.documentURL = documentURL
        self.vaultRootURL = vaultRootURL
    }

    var body: some View {
        Group {
            if let image {
                image.resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if didFinishLoading {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.mutedInk)
                    Text("Missing image: \(source)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: lookupID) {
            let loadRequest = loadRequestGate.begin()
            didFinishLoading = false
            image = nil

            var resolvedURL = url
            if resolvedURL == nil, let rootURL = vaultRootURL {
                let sourceCopy = source
                let documentURLCopy = documentURL
                resolvedURL = await Task.detached(priority: .utility) {
                    VaultStore.resolveImageURL(sourceCopy,
                                               relativeTo: documentURLCopy,
                                               rootURL: rootURL)
                }.value
            }

            guard loadRequestGate.accepts(loadRequest), let resolvedURL else {
                guard loadRequestGate.accepts(loadRequest) else { return }
                didFinishLoading = true
                return
            }

            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: resolvedURL)
            }.value
            guard loadRequestGate.accepts(loadRequest) else { return }
            if let data, let decoded = Image(platformData: data) {
                image = decoded
            }
            didFinishLoading = true
        }
    }

    private var lookupID: String {
        [source, url?.path ?? "", documentURL?.path ?? "", vaultRootURL?.path ?? ""]
            .joined(separator: "\u{1F}")
    }
}

/// A cancellation-resistant token for detached preview work. SwiftUI can cancel a task during
/// a navigation transition even though the current view still needs the result; a newer token,
/// not cancellation alone, determines whether a result is stale.
private struct PreviewRequestGate {
    struct Request: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0

    mutating func begin() -> Request {
        generation &+= 1
        return Request(generation: generation)
    }

    func accepts(_ request: Request) -> Bool {
        request.generation == generation
    }
}

/// Notion-style table: shaded header, hairline grid, equal-width flexible columns.
private struct TableBlock: View {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            row(cells: headers, isHeader: true)
            ForEach(rows.indices, id: \.self) { r in
                Divider()
                row(cells: rows[r], isHeader: false)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .frame(maxWidth: .infinity)
    }

    private func row(cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { c in
                let value = c < cells.count ? cells[c] : ""
                Text(value)
                    .font(isHeader ? .subheadline.bold() : .subheadline)
                    .foregroundStyle(isHeader ? Theme.ink : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .leading) {
                        if c > 0 { Divider() }
                    }
            }
        }
        .background(isHeader ? Theme.surface : Color.clear)
    }
}
