#if os(macOS)
import SwiftUI

struct SoftwareUpdateCommands: Commands {
    @ObservedObject private var updater = SoftwareUpdate.shared
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.check() }.disabled(updater.isBusy)
        }
    }
}

struct SoftwareUpdatePresentation: ViewModifier {
    @ObservedObject private var updater = SoftwareUpdate.shared
    func body(content: Content) -> some View {
        content
            .disabled(updater.blocksEditing)
            .sheet(isPresented: $updater.showUpdate) { SoftwareUpdateView(updater: updater) }
            .task { updater.start() }
    }
}

struct SoftwareUpdateSettings: View {
    @ObservedObject private var updater = SoftwareUpdate.shared
    @AppStorage("automaticallyCheckForUpdates") private var automatic = true
    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.rowVertical) {
            HStack {
                Label("Version \(updater.currentVersion)", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Check for Updates…") { updater.check() }.disabled(updater.isBusy)
            }
            Toggle("Automatically Check for Updates", isOn: $automatic)
            Text("Checks for new versions once a day when ClipNest opens. Updates are installed only when you choose to download and restart.")
                .font(.caption).foregroundStyle(Theme.mutedInk)
        }.padding(.vertical, AppMetrics.rowVertical)
    }
}

struct SoftwareUpdateView: View {
    @ObservedObject var updater: SoftwareUpdate
    @EnvironmentObject private var store: VaultStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app").font(.system(size: 30)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Software Update").font(.title2.bold())
                    Text("Installed version: \(updater.currentVersion)").font(.caption).foregroundStyle(Theme.mutedInk)
                }
            }
            switch updater.state {
            case .idle, .checking:
                ProgressView("Checking for updates…")
            case .current:
                Label("ClipNest is up to date.", systemImage: "checkmark.circle")
            case .available:
                if let release = updater.release {
                    Text("ClipNest \(release.version) is available.").font(.headline)
                    Text("Your notes will be saved before ClipNest restarts.").font(.callout).foregroundStyle(Theme.mutedInk)
                }
            case .downloading:
                ProgressView(value: updater.progress)
                Text("Downloading update… \(Int(updater.progress * 100))%")
            case .preparing:
                ProgressView("Verifying update…")
            case .installing:
                ProgressView("Saving notes and restarting…")
            case .failed:
                Label(updater.errorMessage ?? String(localized: "The update could not be completed."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.mutedInk).textSelection(.enabled)
            }
            if let release = updater.release, !release.notes.isEmpty, !updater.isBusy {
                ScrollView { Text(release.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 200)
            }
            Divider()
            HStack {
                Link("Release Notes", destination: ClipNestUpdateIdentity.releasesURL)
                Spacer()
                if updater.isBusy {
                    if updater.state != .installing { Button("Cancel") { updater.cancel() } }
                } else {
                    Button("Close") { updater.showUpdate = false }
                    if updater.release != nil {
                        Button("Download and Restart") { updater.downloadAndInstall(store: store) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Check Again") { updater.check() }
                    }
                }
            }
        }
        .padding(24).frame(width: 480)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(VSCode.accent)
        .interactiveDismissDisabled(updater.isBusy)
    }
}
#endif
