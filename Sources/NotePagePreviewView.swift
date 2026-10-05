import SwiftUI

struct NotePagePreviewView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onOpen: () -> Void
    @State private var text: String?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if let text { MarkdownPreview(markdown: text, resolveImage: { store.resolveImageURL($0, relativeTo: url) }, documentURL: url, vaultRootURL: store.rootURL) }
                else if let error { Text(error) }
                else { ProgressView() }
            }
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open Note") { dismiss(); onOpen() } }
            }
            .task { do { text = try await store.loadText(url) } catch { self.error = error.localizedDescription } }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
    }
}
