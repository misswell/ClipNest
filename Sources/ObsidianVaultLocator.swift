import Foundation

/// A vault Obsidian created, discovered by scanning Obsidian's default folders.
struct ObsidianVault: Identifiable, Hashable, Sendable {
    let url: URL
    let isICloudDrive: Bool

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
}

/// Finds the vaults Obsidian keeps in its default folders so the user does not have to
/// navigate the whole file system every time they switch vaults.
///
/// Obsidian stores vaults in exactly two well-known places:
///
/// * **iCloud Drive → Obsidian** — the `iCloud~md~obsidian` ubiquity container.
/// * **On My iPhone / iPad** — inside Obsidian's own app container.
///
/// The macOS build is not sandboxed, so it can enumerate those folders directly. The iOS build
/// is sandboxed and holds no entitlement for another app's container, so there discovery can
/// only report folders the user has already granted access to — which is exactly what the
/// recent-vaults list holds. That is why `includingRecent` is part of the search: after the
/// first manual pick the Obsidian vault keeps showing up as a one-tap shortcut.
enum ObsidianVaultLocator {
    /// Obsidian writes this settings folder into every vault. It is the only reliable marker —
    /// the folder name tells us nothing.
    static let vaultMarkerName = ".obsidian"

    /// Folders Obsidian creates vaults in by default, most likely first.
    static var defaultRoots: [URL] {
        // `homeDirectoryForCurrentUser` is unavailable on iOS; `NSHomeDirectory()` is the
        // portable spelling (the app container there, the user's home on macOS).
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var roots = [
            home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents",
                                        isDirectory: true)
        ]
        #if os(macOS)
        roots.append(home.appendingPathComponent("Documents/Obsidian", isDirectory: true))
        roots.append(home.appendingPathComponent("Obsidian", isDirectory: true))
        // "Create new vault" in Obsidian for macOS still defaults to ~/Documents.
        roots.append(home.appendingPathComponent("Documents", isDirectory: true))
        #endif
        return roots
    }

    /// A folder is an Obsidian vault when it carries Obsidian's own settings folder.
    static func isVault(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let marker = url.appendingPathComponent(vaultMarkerName, isDirectory: true)
        guard fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// True when the folder sits inside one of Obsidian's containers. Used to surface vaults
    /// that were opened before, and to label them in the UI.
    static func looksLikeObsidianLocation(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("icloud~md~obsidian")
            || path.contains("/obsidian/")
            || path.hasSuffix("/obsidian")
    }

    /// iCloud Drive vaults live under `~/Library/Mobile Documents`, inside Obsidian's
    /// `iCloud~md~obsidian` ubiquity container.
    static func isICloudDrive(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("mobile documents") || path.contains("icloud~md~obsidian")
    }

    /// Vaults found in Obsidian's default folders, most recently used first.
    ///
    /// Runs a handful of shallow directory listings, so it is cheap enough to do on demand
    /// from a settings row — but keep it off the main actor anyway.
    ///
    /// - Parameter roots: overrides `defaultRoots`. Only tests pass this.
    static func discoverVaults(includingRecent recent: [URL] = [],
                               roots: [URL]? = nil,
                               limit: Int = 12,
                               fileManager: FileManager = .default) -> [ObsidianVault] {
        var found: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            found.append(url)
        }

        // Vaults the user already opened from an Obsidian folder are known to be reachable.
        // Inside the iOS sandbox this is the only source that can produce anything.
        for url in recent where looksLikeObsidianLocation(url) { add(url) }

        var searchRoots = roots ?? defaultRoots
        searchRoots.append(contentsOf: recent
            .filter { looksLikeObsidianLocation($0) }
            .map { $0.deletingLastPathComponent() })

        for root in searchRoots {
            guard found.count < limit else { break }
            guard fileManager.fileExists(atPath: root.path) else { continue }

            if isVault(root, fileManager: fileManager) { add(root) }

            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

            for child in children.sorted(by: mostRecentlyModifiedFirst) {
                guard found.count < limit else { break }
                guard isVault(child, fileManager: fileManager) else { continue }
                add(child)
            }
        }

        return found.map { ObsidianVault(url: $0, isICloudDrive: isICloudDrive($0)) }
    }

    private static func mostRecentlyModifiedFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
        }
        return modified(lhs) > modified(rhs)
    }
}
