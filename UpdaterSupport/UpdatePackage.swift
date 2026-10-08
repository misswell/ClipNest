#if os(macOS)
import CryptoKit
import Foundation
import Security

enum ClipNestUpdatePackage {
    static func sha256(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unpack(_ archive: URL, release: ClipNestUpdateRelease, into directory: URL) throws -> URL {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(release.size), try sha256(at: archive) == release.sha256 else { throw ClipNestUpdateError.checksum }
        let summary = try run("/usr/bin/zipinfo", ["-t", archive.path])
        let expression = try NSRegularExpression(pattern: #"([0-9]+) bytes uncompressed"#)
        guard let match = expression.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let range = Range(match.range(at: 1), in: summary),
              let expandedSize = Int64(summary[range]), expandedSize <= 2 * 1024 * 1024 * 1024 else {
            throw ClipNestUpdateError.invalidApplication
        }
        // Check paths before extraction, including symlinks that could escape staging.
        let listing = try run("/usr/bin/zipinfo", ["-1", archive.path])
        let entries = listing.split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            !entry.hasPrefix("/") && !entry.split(separator: "/").contains("..")
                && (entry.hasPrefix("ClipNest.app/") || entry.hasPrefix("__MACOSX/"))
        }) else { throw ClipNestUpdateError.invalidApplication }
        let modes = try run("/usr/bin/zipinfo", ["-l", archive.path])
        guard !modes.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw ClipNestUpdateError.invalidApplication }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let app = directory.appendingPathComponent("ClipNest.app", isDirectory: true)
        try validate(app, version: release.version)
        return app
    }

    static func info(at app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ClipNestUpdateError.invalidApplication
        }
        return info
    }

    static func validate(_ app: URL, version: String, assessGatekeeper: Bool = true) throws {
        try Task.checkCancellation()
        let metadata = try info(at: app)
        guard let expectedVersion = ClipNestUpdateVersion(version),
              metadata["CFBundleIdentifier"] as? String == ClipNestUpdateIdentity.bundleID,
              metadata["CFBundleExecutable"] as? String == "ClipNest",
              (metadata["CFBundleShortVersionString"] as? String).flatMap(ClipNestUpdateVersion.init) == expectedVersion,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/ClipNest").path),
              FileManager.default.isExecutableFile(atPath: ClipNestUpdateIdentity.helper(in: app).path) else {
            throw ClipNestUpdateError.invalidApplication
        }
        if let minimum = metadata["LSMinimumSystemVersion"] as? String,
           let required = ClipNestUpdateVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard required <= ClipNestUpdateVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")! else {
                throw ClipNestUpdateError.incompatibleSystem
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try run("/usr/bin/lipo", [app.appendingPathComponent("Contents/MacOS/ClipNest").path, "-verify_arch", architecture])
        try run("/usr/bin/lipo", [ClipNestUpdateIdentity.helper(in: app).path, "-verify_arch", architecture])
        try verifySignature(app)
        if assessGatekeeper { try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) }
    }

    static func verifySignature(_ app: URL) throws {
        let requirement = "anchor apple generic and identifier \"\(ClipNestUpdateIdentity.bundleID)\" and certificate leaf[subject.OU] = \"\(ClipNestUpdateIdentity.teamID)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecStaticCode?
        var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let code, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), rule) == errSecSuccess else {
            throw ClipNestUpdateError.signature
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while the child is running so a verbose archive listing cannot fill the pipe.
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClipNestUpdateError.commandFailed }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
