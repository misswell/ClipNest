import SwiftUI

struct RenameItemTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

/// A failed rename keeps the entered name visible so the user can correct it.
struct RenameItemView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    private let isDirectory: Bool
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isRenaming = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        self.isDirectory = isDirectory
        _name = State(initialValue: isDirectory ? fileURL.lastPathComponent
                      : fileURL.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .onSubmit { rename() }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.mutedInk)
                }
                if isRenaming { ProgressView("Updating links…") }
            }
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isRenaming)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") { rename() }
                        .disabled(isRenaming || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isRenaming)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 200)
        #endif
    }

    private func rename() {
        guard !isRenaming else { return }
        var submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = fileURL.pathExtension
        if !isDirectory, !suffix.isEmpty, !submittedName.lowercased().hasSuffix("." + suffix.lowercased()) {
            submittedName += "." + suffix
        }
        isRenaming = true
        Task {
            let destination = await store.renameWithLinks(fileURL, to: submittedName)
            isRenaming = false
            guard destination != nil else {
                errorMessage = store.operationError ?? String(localized: "The item could not be renamed.")
                store.operationError = nil
                return
            }
            dismiss()
        }
    }
}
