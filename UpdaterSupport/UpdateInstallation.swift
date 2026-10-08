#if os(macOS)
import Foundation
import Darwin

/// Same-volume swaps keep a complete old bundle until the new application has launched.
/// The callbacks let tests exercise replacement and rollback without launching a real app.
enum ClipNestUpdateInstallation {
    static func install(source: URL, destination: URL,
                        validate: (URL) throws -> Void,
                        launch: (URL) throws -> Void,
                        rollbackLaunch: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let incoming = parent.appendingPathComponent(".ClipNest-update-\(token).app")
        // After the atomic exchange, incoming contains the complete previous app.
        var keepBackup = false
        defer { if !keepBackup { try? manager.removeItem(at: incoming) } }
        try manager.copyItem(at: source, to: incoming)
        try validate(incoming)
        guard renameatx_np(AT_FDCWD, incoming.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try launch(destination)
        } catch {
            let failure = error
            guard renameatx_np(AT_FDCWD, incoming.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                // Keep the backup where it is; never delete the last known good app.
                keepBackup = true
                throw ClipNestUpdateError.rollbackFailed(incoming.path)
            }
            try? rollbackLaunch(destination)
            throw failure
        }
    }
}
#endif
