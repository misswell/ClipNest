import SwiftUI

private enum KnowledgeSection: String, CaseIterable, Identifiable {
    case notes = "Notes", bookmarks = "Bookmarks", tags = "Tags", graph = "Graph", templates = "Templates", properties = "Properties"
    var id: String { rawValue }
}

struct KnowledgeHubView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var index: VaultKnowledgeIndex
    @Environment(\.dismiss) private var dismiss
    @State private var section: KnowledgeSection = .notes
    @State private var query = ""
    @State private var showNewNote = false
    @State private var newPath = ""
    @State private var showSettings = false
    @State private var property = ""
    @State private var selectedURL: URL?

    private var filtered: [NoteKnowledge] {
        index.sortedNotes.filter { note in
            if section == .bookmarks && !index.isBookmarked(note.url) { return false }
            if section == .templates && !note.url.path.contains("/" + NoteLibrarySettings.templateFolder + "/") { return false }
            return NoteSearchQuery.matches(query, note: note, root: index.root)
        }.sorted {
            if section == .properties && !property.isEmpty {
                let a = $0.properties[property] ?? "", b = $1.properties[property] ?? ""
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $section) {
                    ForEach(KnowledgeSection.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, AppMetrics.screenHorizontal)
                if index.isLoading { ProgressView("Updating note index…").padding(8) }
                if section == .graph {
                    KnowledgeGraphView(notes: filtered, index: index, onSelect: open)
                } else {
                    list
                }
            }
            .navigationTitle("Knowledge")
            .searchable(text: $query, prompt: "Search notes, tag: or path:")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New Note") { newPath = ""; showNewNote = true }
                        Button("Open Daily Note") {
                            store.openDailyNote()
                            if let url = store.selectedFileURL { open(url) }
                        }
                        Button("Random Note") { if let note = filtered.randomElement() { open(note.url) } }
                        Button("New Template") { newPath = NoteLibrarySettings.templateFolder + "/"; showNewNote = true }
                        Button("New Canvas") { newPath = "Untitled.canvas"; showNewNote = true }
                        Button("New Base") { newPath = "Notes.base"; showNewNote = true }
                        Button("Refresh") { index.refresh() }
                        Button("Command Palette") { store.showCommandPalette = true }
                        Button("Note Library Settings") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Knowledge Actions")
                    .disabled(store.rootURL == nil)
                }
            }
            .navigationDestination(item: $selectedURL) { VaultDocumentDestination(url: $0) }
            .alert("New Note", isPresented: $showNewNote) {
                TextField("Relative path", text: $newPath)
                Button("Create") { if let url = store.openOrCreateNote(path: newPath) { open(url) } }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $showSettings) { NoteLibrarySettingsView() }
            .task { index.ensureLoaded() }
        }
        .tint(Theme.accent)
    }

    private var list: some View {
        List {
            if store.rootURL == nil { Text("Open a vault to browse notes.") }
            else if filtered.isEmpty && !index.isLoading { Text("No matching notes") }
            if !index.errors.isEmpty {
                Section("Index Status") {
                    Text("Some notes could not be indexed. Open an iCloud note to download it, then refresh.")
                        .font(.caption).foregroundStyle(Theme.mutedInk)
                    DisclosureGroup("Details (\(index.errors.count))") {
                        ForEach(Array(index.errors.prefix(30).enumerated()), id: \.offset) { _, error in Text(error).font(.caption) }
                    }
                }
            }
            if section == .tags {
                let tags = Set(filtered.flatMap(\.tags)).sorted()
                ForEach(tags, id: \.self) { tag in
                    DisclosureGroup("#" + tag) {
                        ForEach(filtered.filter { $0.tags.contains(tag) }, id: \.url) { note in noteRow(note) }
                    }
                }
            } else {
                if section == .properties {
                    TextField("Sort by property name", text: $property)
                        .textFieldStyle(.roundedBorder)
                }
                ForEach(filtered, id: \.url) { note in noteRow(note) }
            }
        }
    }

    private func noteRow(_ note: NoteKnowledge) -> some View {
        Button { open(note.url) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.url.deletingPathExtension().lastPathComponent).foregroundStyle(Theme.ink)
                    if index.isBookmarked(note.url) { Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent) }
                }
                Text(index.root.map { MarkdownKnowledge.relativePath(note.url, to: $0) } ?? note.url.lastPathComponent)
                    .font(.caption).foregroundStyle(Theme.mutedInk)
                if section == .properties {
                    Text(note.properties.keys.sorted().map { $0 + ": " + (note.properties[$0] ?? "") }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.mutedInk).lineLimit(3)
                }
            }
        }
        .contextMenu {
            Button(index.isBookmarked(note.url) ? "Remove Bookmark" : "Add Bookmark") { index.toggleBookmark(note.url) }
        }
    }

    private func open(_ url: URL) {
        #if os(macOS)
        store.selectedFileURL = url
        store.showKnowledge = false
        dismiss()
        #else
        selectedURL = url
        #endif
    }
}

struct NoteInspectorView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var index: VaultKnowledgeIndex
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @Binding var text: String
    var onOpen: (URL) -> Void
    var onHeading: (String) -> Void
    @State private var showProperties = false
    @State private var versions: [NoteVersion] = []
    @State private var historyError: String?
    @State private var restoreTarget: NoteVersion?
    @State private var templateError: String?
    @State private var showComposer = false
    @State private var showRecorder = false
    @State private var showLocalGraph = false
    @State private var previewNote: RenameItemTarget?

    private var note: NoteKnowledge { MarkdownKnowledge.analyze(text, url: url) }
    private var templates: [NoteKnowledge] {
        index.sortedNotes.filter { $0.url.path.contains("/" + NoteLibrarySettings.templateFolder + "/") }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Words: \(note.words) · Characters: \(note.characters)")
                    Button(index.isBookmarked(url) ? "Remove Bookmark" : "Add Bookmark") { index.toggleBookmark(url) }
                    Button("Compose Notes") { store.save(text, to: url); showComposer = true }
                    Button("Record Audio") { showRecorder = true }
                }
                Section("Outline") {
                    if note.headings.isEmpty { Text("No headings") }
                    ForEach(note.headings) { heading in
                        Button { dismiss(); onHeading(heading.title) } label: {
                            Text(heading.title).padding(.leading, CGFloat(heading.level - 1) * 12)
                        }
                    }
                }
                Section("Properties") {
                    ForEach(note.properties.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: note.properties[key] ?? "")
                    }
                    Button("Edit Properties") { showProperties = true }
                }
                Section("Footnotes") {
                    ForEach(NoteFootnotes.definitions(in: text)) { footnote in
                        Button(footnote.id + ". " + footnote.text) { dismiss(); onHeading("^fn-" + footnote.id) }
                    }
                }
                Section("Outgoing Links") {
                    ForEach(Array(note.links.filter { !$0.isEmbed && !MarkdownKnowledge.isExternal($0.target) }.enumerated()), id: \.offset) { _, link in
                        if let target = index.resolve(link.target, from: url) {
                            Button(link.label) { dismiss(); onOpen(target) }
                        } else {
                            Text(link.label + " — " + String(localized: "Unresolved link"))
                                .foregroundStyle(Theme.mutedInk)
                        }
                    }
                }
                Section("Backlinks") {
                    let incoming = index.backlinks(to: url)
                    if index.isLoading { ProgressView() }
                    else if incoming.isEmpty { Text("No backlinks") }
                    ForEach(incoming, id: \.url) { note in
                        Button(note.url.deletingPathExtension().lastPathComponent) { dismiss(); onOpen(note.url) }
                            .contextMenu { Button("Preview Note") { previewNote = RenameItemTarget(url: note.url) } }
                    }
                    Button("Local Graph") { showLocalGraph = true }
                }
                Section("Unlinked Mentions") {
                    ForEach(index.unlinkedMentions(to: url), id: \.url) { note in
                        Button(note.url.deletingPathExtension().lastPathComponent) { dismiss(); onOpen(note.url) }
                    }
                }
                Section("Templates") {
                    if templates.isEmpty { Text("Create Markdown templates in your Templates folder.") }
                    ForEach(templates, id: \.url) { template in
                        Button(template.url.deletingPathExtension().lastPathComponent) {
                            Task {
                                do {
                                    let body = try await VaultFileAccess.shared.readText(at: template.url)
                                    let expanded = NoteTemplate.expand(body, title: url.deletingPathExtension().lastPathComponent)
                                    text = TemplateInsertion.insert(expanded, into: text)
                                    store.save(text, to: url)
                                    dismiss()
                                } catch { templateError = error.localizedDescription }
                            }
                        }
                    }
                    if let templateError { Text(templateError).foregroundStyle(Theme.mutedInk) }
                }
                Section("File Recovery") {
                    if let historyError { Text(historyError) }
                    else if versions.isEmpty { Text("Previous versions appear after you edit and save this note.") }
                    ForEach(versions) { version in
                        Button { restoreTarget = version } label: {
                            VStack(alignment: .leading) {
                                Text(version.date, style: .date) + Text(" ") + Text(version.date, style: .time)
                                Text(String(version.text.prefix(120))).font(.caption).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Note Details")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showProperties) { NotePropertiesEditor(text: $text, url: url) }
            .sheet(isPresented: $showComposer) { NoteComposerView(url: url, text: $text, onOpen: { dismiss(); onOpen($0) }) }
            .sheet(isPresented: $showRecorder) { NoteAudioRecorderView(document: url, text: $text) }
            .sheet(item: $previewNote) { target in NotePagePreviewView(url: target.url, onOpen: { dismiss(); onOpen(target.url) }) }
            .sheet(isPresented: $showLocalGraph) {
                NavigationStack {
                    KnowledgeGraphView(notes: index.localGraph(for: url), index: index, onSelect: { showLocalGraph = false; dismiss(); onOpen($0) })
                        .navigationTitle("Local Graph")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showLocalGraph = false } } }
                }
            }
            .sheet(item: $restoreTarget) { version in
                NavigationStack {
                    ScrollView { Text(version.text).textSelection(.enabled).padding(AppMetrics.screenHorizontal) }
                        .navigationTitle("Previous Version")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { restoreTarget = nil } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Restore") { text = version.text; store.save(text, to: url); restoreTarget = nil; dismiss() }
                            }
                        }
                }
            }
            .task {
                index.ensureLoaded()
                guard let root = store.rootURL else { return }
                do { versions = try await Task.detached(priority: .utility) { try VaultHistory.versions(for: url, root: root) }.value }
                catch { historyError = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }
}

struct NotePropertiesEditor: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let url: URL
    @State private var yaml = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Edit YAML properties without changing the note body. Existing lists and custom fields are preserved.")
                    .font(.caption).foregroundStyle(Theme.mutedInk)
                TextEditor(text: $yaml).font(.system(.body, design: .monospaced))
                if let error { Text(error).foregroundStyle(Theme.mutedInk) }
            }
            .padding(AppMetrics.screenHorizontal)
            .navigationTitle("Edit Properties")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            text = try TemplateInsertion.replacingProperties(in: text, yaml: yaml)
                            store.save(text, to: url)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .onAppear {
                if let range = MarkdownKnowledge.frontmatterRange(in: text) {
                    var lines = (text as NSString).substring(with: range).components(separatedBy: "\n")
                    lines.removeFirst()
                    if lines.last == "" { lines.removeLast() }
                    if !lines.isEmpty { lines.removeLast() }
                    yaml = lines.joined(separator: "\n")
                }
            }
        }
    }
}

struct KnowledgeGraphView: View {
    let notes: [NoteKnowledge]
    @ObservedObject var index: VaultKnowledgeIndex
    let onSelect: (URL) -> Void
    @State private var zoom: CGFloat = 1
    private let size: CGFloat = 900

    var body: some View {
        let visible = Array(notes.prefix(120))
        let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { i, note in
            let angle = Double(i) * 2 * Double.pi / Double(max(visible.count, 1))
            let radius = visible.count == 1 ? 0.0 : 320.0
            return (note.url, CGPoint(x: 450 + cos(angle) * radius, y: 450 + sin(angle) * radius))
        })
        VStack {
            HStack {
                Text("\(visible.count) notes · Tap a note to open")
                Spacer()
                Button { zoom = max(0.4, zoom - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom = min(2, zoom + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
            }.font(.caption).padding(8)
            if notes.count > 120 { Text("Showing the first 120 matches. Search to narrow the graph.").font(.caption) }
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Canvas { context, _ in
                        var path = Path()
                        for note in visible {
                            guard let from = positions[note.url] else { continue }
                            for link in note.links {
                                guard let target = index.resolve(link.target, from: note.url), let to = positions[target] else { continue }
                                path.move(to: from); path.addLine(to: to)
                            }
                        }
                        context.stroke(path, with: .color(Theme.mutedInk.opacity(0.4)), lineWidth: 1)
                    }
                    ForEach(visible, id: \.url) { note in
                        Button { onSelect(note.url) } label: {
                            VStack(spacing: 3) {
                                Circle().fill(Theme.accent).frame(width: 14, height: 14)
                                Text(note.url.deletingPathExtension().lastPathComponent)
                                    .font(.caption2).lineLimit(2).frame(width: 110)
                                    .foregroundStyle(Theme.ink).padding(3).background(Theme.background.opacity(0.9))
                            }
                        }.buttonStyle(.plain).position(positions[note.url] ?? .zero)
                    }
                }
                .frame(width: size, height: size)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: size * zoom, height: size * zoom, alignment: .topLeading)
            }
        }
    }
}
