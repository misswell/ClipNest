import SwiftUI

struct DesktopWorkspace: Codable, Identifiable {
    var id: String { name }
    let name: String
    var tabs: [String]
    var selected: String?
    let activity: String
    let sidebarVisible: Bool
    let sidebarWidth: Double
    let terminalVisible: Bool
    let terminalWidth: Double
    let mode: String
    let multipleTabs: Bool

    func urls(in root: URL) -> [URL] {
        tabs.map { root.appendingPathComponent($0).standardizedFileURL }.filter {
            VaultNoteCatalog.isInside($0, root: root) && FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

enum DesktopWorkspaceRepository {
    static func load(root: URL) -> [DesktopWorkspace] {
        guard let data = UserDefaults.standard.data(forKey: key(root)) else { return [] }
        return (try? JSONDecoder().decode([DesktopWorkspace].self, from: data)) ?? []
    }
    static func save(_ workspaces: [DesktopWorkspace], root: URL) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(workspaces), forKey: key(root))
    }
    static func relocate(_ move: VaultDocumentMove, root: URL) {
        var workspaces = load(root: root)
        for i in workspaces.indices {
            workspaces[i].tabs = workspaces[i].tabs.map {
                MarkdownKnowledge.relativePath(move.relocated(root.appendingPathComponent($0)), to: root)
            }
            if let selected = workspaces[i].selected {
                workspaces[i].selected = MarkdownKnowledge.relativePath(move.relocated(root.appendingPathComponent(selected)), to: root)
            }
        }
        if !workspaces.isEmpty { try? save(workspaces, root: root) }
    }
    private static func key(_ root: URL) -> String { "desktop.workspaces." + root.standardizedFileURL.path }
}

#if os(macOS)
struct DesktopWorkspaceManager: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let current: (String) -> DesktopWorkspace
    let onLoad: (DesktopWorkspace) -> Void
    @State private var layouts: [DesktopWorkspace] = []
    @State private var name = ""
    @State private var error: String?
    @State private var deleteTarget: DesktopWorkspace?

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    TextField("Workspace name", text: $name)
                    Button("Save Layout") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        var updated = layouts.filter { $0.name != trimmed }
                        updated.append(current(trimmed))
                        persist(updated.sorted { $0.name < $1.name })
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Saving an existing name updates that layout. Terminal visibility is saved; running commands are not restarted.")
                    .font(.caption).foregroundStyle(Theme.mutedInk)
                if let error { Text(error) }
                List(layouts) { layout in
                    HStack {
                        VStack(alignment: .leading) { Text(layout.name); Text("\(layout.tabs.count) tabs").font(.caption) }
                        Spacer()
                        Button("Load") { onLoad(layout); dismiss() }
                        Button("Delete", role: .destructive) { deleteTarget = layout }
                    }
                }
            }.padding(AppMetrics.screenHorizontal)
                .navigationTitle("Workspaces")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onAppear { layouts = DesktopWorkspaceRepository.load(root: root) }
                .alert("Delete Workspace?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                    Button("Delete", role: .destructive) { if let deleteTarget { persist(layouts.filter { $0.id != deleteTarget.id }) }; deleteTarget = nil }
                    Button("Cancel", role: .cancel) { deleteTarget = nil }
                }
        }.frame(minWidth: 600, minHeight: 440)
    }
    private func persist(_ values: [DesktopWorkspace]) {
        do { try DesktopWorkspaceRepository.save(values, root: root); layouts = values }
        catch { self.error = error.localizedDescription }
    }
}
#endif
