#if os(macOS)
import Foundation

enum ClipNestUpdateIdentity {
    static let bundleID = "com.tertiaryinfotech.clipnest"
    static let teamID = "U8U443D7ZL"
    static let repository = "misswell/ClipNest"
    static let helperName = "ClipNestUpdater"
    static let maximumArchiveSize: Int64 = 512 * 1024 * 1024
    static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static func helper(in app: URL) -> URL { app.appendingPathComponent("Contents/MacOS/\(helperName)") }
}

struct ClipNestUpdateVersion: Comparable, Sendable {
    let components: [Int]
    init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.compactMap({ Int($0) }).count == parts.count else { return nil }
        var numbers = parts.compactMap { Int($0) }
        while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

struct ClipNestUpdateRelease: Equatable, Sendable {
    let version: String
    let notes: String
    let archiveURL: URL
    let sha256: String
    let size: Int64

    func isNewer(than version: String) -> Bool {
        guard let current = ClipNestUpdateVersion(version), let candidate = ClipNestUpdateVersion(self.version) else { return false }
        return candidate > current
    }

    static func decode(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
                let size: Int64
                let state: String
            }
            let tag_name: String
            let body: String?
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ClipNestUpdateError.invalidRelease }
        guard !response.draft, !response.prerelease, response.tag_name.hasPrefix("v"),
              ClipNestUpdateVersion(response.tag_name) != nil else { throw ClipNestUpdateError.invalidRelease }
        let version = String(response.tag_name.dropFirst())
        let name = "ClipNest-\(version)-macos.zip"
        let expectedURL = URL(string: "https://github.com/\(ClipNestUpdateIdentity.repository)/releases/download/\(response.tag_name)/\(name)")!
        guard let asset = response.assets.first(where: { $0.name == name }), asset.state == "uploaded",
              asset.browser_download_url == expectedURL,
              asset.size > 0, asset.size <= ClipNestUpdateIdentity.maximumArchiveSize,
              let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") else {
            throw ClipNestUpdateError.invalidRelease
        }
        let hash = String(digest.dropFirst(7))
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw ClipNestUpdateError.invalidRelease }
        return Self(version: version, notes: response.body ?? "", archiveURL: expectedURL, sha256: hash, size: asset.size)
    }
}

enum ClipNestUpdateError: LocalizedError {
    case invalidRelease, network(Int), checksum, invalidApplication, signature, incompatibleSystem
    case cannotInstall, helperMissing, parentRunning, launchFailed, rollbackFailed(String), commandFailed

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return String(localized: "The release does not contain a verified ClipNest update package.")
        case .network(let status): return String(localized: "The update server returned HTTP \(status). Try again later.")
        case .checksum: return String(localized: "The downloaded update failed its integrity check. Download it again.")
        case .invalidApplication: return String(localized: "The update package has the wrong application identity or version.")
        case .signature: return String(localized: "The update is not signed by the ClipNest developer or was modified.")
        case .incompatibleSystem: return String(localized: "This update requires a newer version of macOS or a different processor.")
        case .cannotInstall: return String(localized: "Move ClipNest to a writable Applications folder before installing updates.")
        case .helperMissing: return String(localized: "The update installer is missing. Download ClipNest from the releases page.")
        case .parentRunning: return String(localized: "ClipNest did not quit in time. The installed application was left unchanged.")
        case .launchFailed: return String(localized: "The updated application could not start. The previous version was restored.")
        case .rollbackFailed(let detail): return String(localized: "The previous version could not be restored: \(detail)")
        case .commandFailed: return String(localized: "The update package could not be unpacked or verified.")
        }
    }
}
#endif
