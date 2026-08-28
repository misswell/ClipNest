import SwiftUI

struct MoveDocumentTarget: Identifiable {
    let url: URL
    var id: String { url.standardizedFileURL.path }
}

/// Folder picker used by both the iPhone Vault tree and the macOS Explorer.
/// It moves the real Markdown file through VaultStore, so the vault remains the
/// source of truth and the selected document follows its new URL.
struct MoveDocumentView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    let fileURL: URL
    let onCompleted: () -> Void

    @State private var destination: URL?
    @State private var errorMessage: String?

    init(fileURL: URL, onCompleted: @escaping () -> Void = {}) {
        self.fileURL = fileURL
        self.onCompleted = onCompleted
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Folders") {
                    ForEach(store.vaultDirectories(), id: \.self) { directory in
                        folderRow(directory)
                    }
                }
            }
            .navigationTitle("Move Document")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { moveDocument() }
                        .disabled(!canMove)
                }
            }
            .alert("Cannot Move Document", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "The document could not be moved.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func folderRow(_ directory: URL) -> some View {
        let isCurrentDirectory = directory.standardizedFileURL
            == fileURL.deletingLastPathComponent().standardizedFileURL
        let isSelected = destination?.standardizedFileURL == directory.standardizedFileURL

        return Button {
            destination = directory
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.accent)
                Text(directory == store.rootURL ? store.vaultName : directory.lastPathComponent)
                    .lineLimit(1)
                Spacer()
                if isCurrentDirectory {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedInk)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.leading, CGFloat(depth(of: directory)) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canMove: Bool {
        guard let destination else { return false }
        return destination.standardizedFileURL
            != fileURL.deletingLastPathComponent().standardizedFileURL
    }

    private func moveDocument() {
        guard let destination, canMove else { return }
        guard store.moveDocument(fileURL, to: destination) != nil else {
            errorMessage = "The destination is unavailable or already contains an invalid path."
            return
        }
        onCompleted()
        dismiss()
    }

    private func depth(of directory: URL) -> Int {
        guard let root = store.rootURL else { return 0 }
        let rootCount = root.standardizedFileURL.pathComponents.count
        let directoryCount = directory.standardizedFileURL.pathComponents.count
        return max(0, directoryCount - rootCount)
    }
}
