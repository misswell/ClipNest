import SwiftUI
import QuickLook

struct VaultAttachmentView: View {
    @EnvironmentObject private var store: VaultStore
    let url: URL
    @State private var preview: URL?
    @State private var temporaryURL: URL?
    @State private var isPreparing = false
    @State private var error: String?
    @State private var preparation: Task<Void, Never>?
    var body: some View {
        VStack(spacing: AppMetrics.sectionSpacing) {
            Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(Theme.accent)
            Text(url.lastPathComponent).font(.headline)
            if let error { Text(error).foregroundStyle(Theme.mutedInk) }
            if isPreparing { ProgressView() }
            Button("Preview Attachment") {
                guard !isPreparing, let root = store.rootURL, VaultNoteCatalog.isInside(url, root: root) else { return }
                isPreparing = true
                preparation = Task {
                    do {
                        if let temporaryURL { preview = temporaryURL }
                        else {
                            let copy = try await VaultFileAccess.shared.mediaPreviewCopy(at: url)
                            if Task.isCancelled { try? FileManager.default.removeItem(at: copy); return }
                            temporaryURL = copy; preview = copy
                        }
                    } catch { self.error = error.localizedDescription }
                    isPreparing = false
                }
            }.buttonStyle(.borderedProminent).disabled(isPreparing)
        }
        .padding(AppMetrics.screenHorizontal).frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .quickLookPreview($preview)
        .onDisappear {
            preparation?.cancel(); preparation = nil; isPreparing = false
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            temporaryURL = nil; preview = nil
        }
    }
}

struct BaseEmbedView: View {
    @EnvironmentObject private var store: VaultStore
    let source: String
    let document: URL
    @State private var url: URL?
    @State private var error: String?
    var body: some View {
        Group {
            if let url { BaseEditorView(url: url, contextURL: document) }
            else if let error { Text(error) }
            else { ProgressView() }
        }.frame(minHeight: 200, maxHeight: 450)
            .task(id: source) {
                if let resolved = await store.resolveNote(source, from: document) { url = resolved }
                else { error = String(localized: "Unresolved link") }
            }
    }
}
