import SwiftUI

struct VaultDocumentDestination: View {
    let url: URL
    var initialHeading: String? = nil
    var body: some View {
        if url.pathExtension.lowercased() == "canvas" { CanvasEditorView(url: url) }
        else if url.pathExtension.lowercased() == "base" { BaseEditorView(url: url) }
        else if FileNode.imageExtensions.contains(url.pathExtension.lowercased()) { ImageFileView(url: url) }
        else if !FileNode.editableExtensions.contains(url.pathExtension.lowercased()) { VaultAttachmentView(url: url) }
        else { MarkdownEditorView(url: url, initialHeading: initialHeading) }
    }
}

struct CanvasEditorView: View {
    @EnvironmentObject private var store: VaultStore
    let url: URL
    @State private var document: JSONCanvasDocument?
    @State private var error: String?
    @State private var editing: CanvasNode?
    @State private var connectFrom: String?
    @State private var deleteTarget: String?
    @State private var showDelete = false
    @State private var zoom: CGFloat = 1
    @State private var linkedURL: URL?
    @State private var retry = 0
    @State private var currentURL: URL?
    private var target: URL { currentURL ?? url }

    var body: some View {
        Group {
            if let document { canvas(document) }
            else if let error {
                VStack { Text(error); Button("Retry") { retry += 1 } }.padding()
            } else { ProgressView("Reading document…") }
        }
        .navigationTitle(target.deletingPathExtension().lastPathComponent)
        .toolbar {
            if document != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Add Card") {
                        Button("Text") { add("text", content: "New card") }
                        Button("File") { add("file", content: "Welcome.md") }
                        Button("Web Link") { add("link", content: "https://example.com") }
                        Button("Group") { add("group", content: "Group") }
                    }
                }
            }
        }
        .task(id: "\(url.path):\(retry)") {
            currentURL = nil; document = nil; error = nil
            do {
                let loaded = try JSONCanvasDocument(text: await store.loadText(url))
                if !Task.isCancelled { document = loaded }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: store.lastLinkMutation) { _, mutation in
            guard let mutation else { return }
            document?.rewriteLinks(using: mutation, at: target)
            currentURL = VaultDocumentMove(source: mutation.source, destination: mutation.destination).relocated(target)
        }
        .sheet(item: $editing) { node in
            CanvasCardEditor(node: node) { values in document?.update(node.id, values: values); save() }
        }
        .alert("Delete Card?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { if let deleteTarget { document?.remove(deleteTarget); save() } }
            Button("Cancel", role: .cancel) { }
        }
        .navigationDestination(item: $linkedURL) { VaultDocumentDestination(url: $0) }
    }

    private func canvas(_ document: JSONCanvasDocument) -> some View {
        let nodes = document.nodes
        let minX = min(nodes.map(\.x).min() ?? 0, 0) - 40
        let minY = min(nodes.map(\.y).min() ?? 0, 0) - 40
        let width = max(1000, (nodes.map { $0.x + $0.width }.max() ?? 0) - minX + 40)
        let height = max(800, (nodes.map { $0.y + $0.height }.max() ?? 0) - minY + 40)
        return VStack(spacing: 0) {
            HStack {
                if connectFrom != nil { Text("Choose a destination card"); Button("Cancel") { connectFrom = nil } }
                Spacer()
                Button { zoom = max(0.2, zoom - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom = min(2, zoom + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
            }.padding(8)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        let map = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                        for edge in document.edges {
                            guard let fromID = edge["fromNode"]?.string, let toID = edge["toNode"]?.string,
                                  let from = map[fromID], let to = map[toID] else { continue }
                            let a = CGPoint(x: from.x + from.width / 2 - minX, y: from.y + from.height / 2 - minY)
                            let b = CGPoint(x: to.x + to.width / 2 - minX, y: to.y + to.height / 2 - minY)
                            var path = Path(); path.move(to: a); path.addLine(to: b)
                            context.stroke(path, with: .color(Theme.accent), lineWidth: 2)
                            if let label = edge["label"]?.string {
                                context.draw(Text(label).font(.caption), at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                            }
                        }
                    }
                    ForEach(nodes) { node in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: node.type == "text" ? "text.alignleft" : "doc")
                                Spacer()
                                Button { editing = node } label: { Image(systemName: "pencil") }
                                    .disabled(!["text", "file", "link", "group"].contains(node.type))
                            }
                            Text(node.content).lineLimit(8)
                            if node.type == "file" { Button("Open Note") { open(node.content) } }
                            if node.type == "link", let link = URL(string: node.content), ["https", "http"].contains(link.scheme) {
                                Link("Open Link", destination: link)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12).frame(width: node.width, height: node.height, alignment: .topLeading)
                        .background(node.type == "group" ? Theme.surface.opacity(0.3) : Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Theme.accent.opacity(0.5)))
                        .position(x: node.x + node.width / 2 - minX, y: node.y + node.height / 2 - minY)
                        .gesture(DragGesture().onEnded { change in
                            self.document?.update(node.id, values: ["x": .number(node.x + change.translation.width / zoom),
                                                                  "y": .number(node.y + change.translation.height / zoom)])
                            save()
                        })
                        .onTapGesture { if let from = connectFrom { self.document?.connect(from: from, to: node.id); connectFrom = nil; save() } }
                        .contextMenu {
                            Button("Connect Card") { connectFrom = node.id }
                            Button("Delete Card", role: .destructive) { deleteTarget = node.id; showDelete = true }
                        }
                    }
                }.frame(width: width, height: height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: width * zoom, height: height * zoom, alignment: .topLeading)
            }
        }
    }

    private func add(_ type: String, content: String) {
        document?.add(type: type, content: content, x: Double(document?.nodes.count ?? 0) * 40, y: 40)
        save()
    }
    private func save() {
        do { if let text = try document?.text() { store.save(text, to: target) } }
        catch { store.operationError = error.localizedDescription }
    }
    private func open(_ path: String) {
        Task {
            if let resolved = await store.resolveNote(path, from: target) {
                #if os(macOS)
                store.selectedFileURL = resolved
                #else
                linkedURL = resolved
                #endif
            }
        }
    }
}

private struct CanvasCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    let node: CanvasNode
    let onSave: ([String: CanvasValue]) -> Void
    @State private var text = ""
    @State private var width = ""
    @State private var height = ""
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text).frame(minHeight: 200)
                TextField("Width", text: $width)
                TextField("Height", text: $height)
            }
            .navigationTitle("Edit Card")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let w = Double(width), let h = Double(height), w > 0, h > 0, w < 10_000, h < 10_000 else { return }
                        onSave([node.contentKey: .string(text), "width": .number(w), "height": .number(h)])
                        dismiss()
                    }
                }
            }
            .onAppear { text = node.content; width = String(node.width); height = String(node.height) }
        }
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 400)
        #endif
    }
}
