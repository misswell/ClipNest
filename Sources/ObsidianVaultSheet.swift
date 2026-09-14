import SwiftUI

/// One-tap switching to a vault Obsidian created, without browsing the whole file system.
///
/// The list is built by `ObsidianVaultLocator`; anything it cannot see (an iOS vault the user
/// has not granted access to yet) is covered by the "Browse for Folder…" fallback and the
/// explanation below the list.
struct ObsidianVaultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let vaults: [ObsidianVault]
    let currentVaultURL: URL?
    let onSwitch: (URL) -> Void
    let onBrowse: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if vaults.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No Obsidian vault found yet")
                                .font(.headline)
                            Text("Pick the folder once with “Browse for Folder…” and ClipNest will offer it here from then on.")
                                .font(.callout)
                                .foregroundStyle(Theme.mutedInk)
                        }
                        .padding(.vertical, AppMetrics.rowVertical)
                    }
                } else {
                    Section {
                        ForEach(vaults) { vault in
                            Button {
                                onSwitch(vault.url)
                            } label: {
                                row(for: vault)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Obsidian Vaults")
                    }
                }

                Section {
                    Button {
                        onBrowse()
                    } label: {
                        Label("Browse for Folder…", systemImage: "folder")
                    }
                    // A footer would be clipped to one line on macOS, so the explanation is a
                    // normal row that is allowed to wrap.
                    Text("Obsidian keeps vaults in iCloud Drive ▸ Obsidian, or on this device under Obsidian. ClipNest opens that folder in place — nothing is copied or moved.")
                        .font(.footnote)
                        .foregroundStyle(Theme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("Obsidian")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private func row(for vault: ObsidianVault) -> some View {
        let isCurrent = vault.url.standardizedFileURL == currentVaultURL?.standardizedFileURL
        return HStack(spacing: 12) {
            Image(systemName: vault.isICloudDrive ? "icloud" : "folder")
                .font(.system(size: AppMetrics.rowIconSize))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .foregroundStyle(Theme.ink)
                Text(vault.url.path)
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("Current")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
