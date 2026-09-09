import SwiftUI

/// The vault recycle bin: lists deleted items with restore / permanent-delete actions,
/// plus an "empty trash" purge. Items auto-expire after 30 days (purged on launch).
struct TrashView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TrashEntry] = []
    @State private var confirmPurgeAll = false
    @State private var pendingPurge: TrashEntry?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("Trash is empty",
                                           systemImage: "trash",
                                           description: Text("Deleted notes and folders are kept here for 30 days."))
                } else {
                    List {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .navigationTitle("Trash")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        confirmPurgeAll = true
                    } label: {
                        Label("Empty Trash", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        confirmPurgeAll = true
                    } label: {
                        Label("Empty Trash", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                }
                #endif
            }
            .alert("Empty Trash?", isPresented: $confirmPurgeAll) {
                Button("Empty", role: .destructive) {
                    store.purgeAllTrash()
                    reload()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Everything in the trash will be permanently deleted.")
            }
            .alert("Delete Permanently",
                   isPresented: Binding(get: { pendingPurge != nil },
                                        set: { if !$0 { pendingPurge = nil } })) {
                Button("Delete", role: .destructive) {
                    if let entry = pendingPurge {
                        store.purgeFromTrash(entry)
                        reload()
                    }
                    pendingPurge = nil
                }
                Button("Cancel", role: .cancel) { pendingPurge = nil }
            } message: {
                Text("This item will be permanently deleted.")
            }
            .onAppear(perform: reload)
        }
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .lineLimit(1)
                Text(entry.originalRelativePath)
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.deletedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedInk)
            }
            Spacer()
            Button {
                store.restoreFromTrash(entry)
                reload()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .help("Restore")
            Button {
                pendingPurge = entry
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(Theme.mutedInk)
            }
            .buttonStyle(.borderless)
            .help("Delete Permanently")
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        entries = store.trashEntries()
    }
}
