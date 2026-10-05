import SwiftUI

private struct BaseRow: Identifiable {
    var id: URL { note.url }
    let note: NoteKnowledge
    let values: [String: CanvasValue]
}

private struct BaseRowGroup: Identifiable {
    let id: String
    let title: String?
    var rows: [BaseRow]
}

struct BaseEditorView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var index: VaultKnowledgeIndex
    let url: URL
    var inlineSource: String? = nil
    var contextURL: URL? = nil
    @State private var source = ""
    @State private var base: NoteBase?
    @State private var rows: [BaseRow] = []
    @State private var view = 0
    @State private var error: String?
    @State private var showConfiguration = false
    @State private var selectedURL: URL?
    @State private var editCell: BaseCellTarget?

    private var current: [String: CanvasValue] { base?.views.indices.contains(view) == true ? base!.views[view] : [:] }
    private var columns: [String] { current["order"]?.array?.compactMap(\.string) ?? ["file.name"] }
    private var renderID: String { "\(index.revision):\(view):" + source }
    private var groups: [BaseRowGroup] {
        guard let property = current["groupBy"]?.object?["property"]?.string else {
            return [BaseRowGroup(id: "all", title: nil, rows: rows)]
        }
        var result: [BaseRowGroup] = []
        for row in rows {
            let value = row.values[property] ?? .null
            let id = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            if result.last?.id == id { result[result.count - 1].rows.append(row) }
            else { result.append(BaseRowGroup(id: id, title: BaseExpression.display(value).isEmpty ? "—" : BaseExpression.display(value), rows: [row])) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if let base {
                Picker("View", selection: $view) {
                    ForEach(base.views.indices, id: \.self) { i in Text(base.views[i]["name"]?.string ?? "View \(i + 1)").tag(i) }
                }.padding(8)
                if index.isLoading { ProgressView("Updating note index…") }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.mutedInk).padding(8) }
                table
            } else if let error {
                Text(error).padding(AppMetrics.screenHorizontal)
                if inlineSource == nil { Button("Edit Base") { showConfiguration = true } }
            } else { ProgressView("Reading document…") }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .toolbar {
            if inlineSource == nil { ToolbarItem(placement: .primaryAction) { Button("Edit Base") { showConfiguration = true } } }
        }
        .task(id: url) {
            index.ensureLoaded()
            do {
                if let inlineSource { source = inlineSource }
                else { source = try await store.loadText(url) }
                base = try NoteBase(source)
            } catch { self.error = error.localizedDescription }
        }
        .task(id: renderID) {
            guard let base, let root = store.rootURL else { return }
            let notes = index.sortedFiles
            let aliases = index.aliases
            let selected = view
            do {
                let result = try await Task.detached(priority: .utility) {
                    try base.rows(view: selected, notes: notes, root: root, url: contextURL ?? url, aliases: aliases)
                }.value
                guard !Task.isCancelled else { return }
                rows = result.map { BaseRow(note: $0.0, values: $0.1) }
                error = nil
            } catch { if !Task.isCancelled { rows = []; self.error = error.localizedDescription } }
        }
        .sheet(isPresented: $showConfiguration) {
            BaseConfigurationEditor(source: source) { updated in
                source = updated; base = try? NoteBase(updated); view = 0; store.save(updated, to: url)
            }
        }
        .sheet(item: $editCell) { target in BasePropertyEditor(target: target) }
        .navigationDestination(item: $selectedURL) { VaultDocumentDestination(url: $0) }
    }

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if current["type"]?.string == "table" || current["type"] == nil { HStack(spacing: 0) {
                    ForEach(columns, id: \.self) { column in
                        Text(base?.data["properties"]?.object?[column]?.object?["displayName"]?.string ?? column)
                            .font(.headline).frame(width: 170, alignment: .leading).padding(8)
                    }
                }.background(Theme.surface) }
                ForEach(groups) { group in
                    if let title = group.title { Text(title).font(.headline).padding(8) }
                    if current["type"]?.string == "cards" {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], alignment: .leading) {
                            ForEach(group.rows) { row in
                                VStack(alignment: .leading) {
                                    Button(row.note.url.deletingPathExtension().lastPathComponent) { open(row.note.url) }.font(.headline)
                                    ForEach(columns, id: \.self) { column in cell(row, column: column, compact: true) }
                                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: AppMetrics.cardRadius))
                            }
                        }
                        .frame(minWidth: 300).padding(8)
                    } else {
                        ForEach(group.rows) { row in
                            if current["type"]?.string == "list" {
                                VStack(alignment: .leading) {
                                    Button(row.note.url.deletingPathExtension().lastPathComponent) { open(row.note.url) }.font(.headline)
                                    ForEach(columns, id: \.self) { column in cell(row, column: column, compact: true) }
                                }.padding(8)
                            } else { HStack(spacing: 0) { ForEach(columns, id: \.self) { column in cell(row, column: column, compact: false) } } }
                            Divider()
                        }
                    }
                }
                if rows.isEmpty && !index.isLoading && error == nil { Text("No matching notes").padding() }
                if let summaries = current["summaries"]?.object {
                    HStack(spacing: 0) {
                        ForEach(columns, id: \.self) { column in
                            let name = summaries[column]?.string ?? ""
                            Text(name.isEmpty ? "" : BaseSummary.text(name: name, values: rows.map { $0.values[column] ?? .null }))
                                .font(.caption).frame(width: 170, alignment: .leading).padding(8)
                        }
                    }.background(Theme.surface)
                }
            }
        }
    }

    private func cell(_ row: BaseRow, column: String, compact: Bool) -> some View {
        Button {
            let key = column.hasPrefix("note.") ? String(column.dropFirst(5)) : column
            if column.hasPrefix("file.") || column.hasPrefix("formula.") || key.contains(".") || key.contains("[") || !FileNode.markdownExtensions.contains(row.note.url.pathExtension.lowercased()) { open(row.note.url) }
            else { editCell = BaseCellTarget(url: row.note.url, key: column.hasPrefix("note.") ? String(column.dropFirst(5)) : column, value: row.values[column] ?? .null) }
        } label: {
            Text(BaseExpression.display(row.values[column] ?? .null).isEmpty ? "—" : BaseExpression.display(row.values[column] ?? .null))
                .lineLimit(3).frame(width: compact ? nil : 170, alignment: .leading).frame(minHeight: 44)
                .padding(compact ? 0 : 8).foregroundStyle(Theme.ink)
        }.buttonStyle(.plain)
    }

    private func open(_ target: URL) {
        #if os(macOS)
        store.selectedFileURL = target
        #else
        selectedURL = target
        #endif
    }
}

struct BaseCellTarget: Identifiable {
    let url: URL
    let key: String
    let value: CanvasValue
    var id: String { url.path + ":" + key }
}

private struct BaseConfigurationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let source: String
    let onSave: (String) -> Void
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text).font(.system(.body, design: .monospaced))
                if let error { Text(error).foregroundStyle(Theme.mutedInk) }
            }.padding(AppMetrics.screenHorizontal).navigationTitle("Edit Base")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        do { _ = try NoteBase(text); onSave(text); dismiss() } catch { self.error = error.localizedDescription }
                    } }
                }.onAppear { text = source }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
    }
}

private struct BasePropertyEditor: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let target: BaseCellTarget
    @State private var text = ""
    @State private var error: String?
    @State private var isSaving = false
    var body: some View {
        NavigationStack {
            Form {
                TextField(target.key, text: $text)
                Text("Use YAML values: text, number, true/false, or a list such as [a, b].").font(.caption)
                if let error { Text(error) }
            }.navigationTitle("Edit Property")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(isSaving) }
                }.onAppear { text = (try? JSONEncoder().encode(target.value)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
        }
    }
    private func save() {
        guard let root = store.rootURL, FileNode.markdownExtensions.contains(target.url.pathExtension.lowercased()) else { return }
        isSaving = true
        let yaml = text
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try VaultFileAccess.performMutation {
                        let data = try VaultFileAccess.readDataImmediately(at: target.url)
                        guard let previous = String(data: data, encoding: .utf8) else { throw VaultAccessError.notUTF8 }
                        let properties = try NoteProperties.parse(NoteProperties.yaml(previous))
                        guard (properties[target.key] ?? .null) == target.value else {
                            throw VaultAccessError.writeFailed(String(localized: "The property changed. Refresh before editing it."))
                        }
                        let value = try NoteProperties.parse("value: " + yaml)["value"] ?? .null
                        let updated = try NoteProperties.setting(value, key: target.key, in: previous)
                        try VaultHistory.record(previous, for: target.url, root: root)
                        try VaultFileAccess.writeDataImmediately(Data(updated.utf8), to: target.url)
                    }
                }.value
                if store.rootURL == root { store.notifyFileChanges([target.url]) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            isSaving = false
        }
    }
}

enum BaseSummary {
    static func text(name: String, values: [CanvasValue]) -> String {
        let numbers = values.compactMap(\.number).sorted()
        let result: CanvasValue
        switch name {
        case "Sum": result = .number(numbers.reduce(0, +))
        case "Average": result = numbers.isEmpty ? .null : .number(numbers.reduce(0, +) / Double(numbers.count))
        case "Min", "Earliest": result = numbers.first.map(CanvasValue.number) ?? values.filter { $0 != .null }.sorted { BaseExpression.display($0) < BaseExpression.display($1) }.first ?? .null
        case "Max", "Latest": result = numbers.last.map(CanvasValue.number) ?? values.filter { $0 != .null }.sorted { BaseExpression.display($0) < BaseExpression.display($1) }.last ?? .null
        case "Range": result = numbers.isEmpty ? .null : .number(numbers.last! - numbers.first!)
        case "Median": result = numbers.isEmpty ? .null : .number((numbers[(numbers.count - 1) / 2] + numbers[numbers.count / 2]) / 2)
        case "Stddev":
            let mean = numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
            result = numbers.isEmpty ? .null : .number(sqrt(numbers.map { pow($0 - mean, 2) }.reduce(0, +) / Double(numbers.count)))
        case "Checked": result = .number(Double(values.filter { $0 == .bool(true) }.count))
        case "Unchecked": result = .number(Double(values.filter { $0 == .bool(false) }.count))
        case "Empty": result = .number(Double(values.filter { $0 == .null || $0 == .string("") }.count))
        case "Filled": result = .number(Double(values.filter { $0 != .null && $0 != .string("") }.count))
        case "Unique":
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            result = .number(Double(Set(values.compactMap { try? encoder.encode($0) }).count))
        default: return String(localized: "Unsupported summary") + ": " + name
        }
        return name + ": " + BaseExpression.display(result)
    }
}
