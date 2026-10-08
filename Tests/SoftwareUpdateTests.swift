import XCTest
import Foundation
import SwiftUI
import AppKit
@testable import ClipNest

final class SoftwareUpdateTests: XCTestCase {
    private func response(version: String = "1.6", digest: String? = "sha256:" + String(repeating: "a", count: 64),
                          prerelease: Bool = false, url: String? = nil, size: Int = 100) throws -> Data {
        let asset: [String: Any] = ["name": "ClipNest-\(version)-macos.zip", "state": "uploaded", "size": size,
                                  "digest": digest as Any? ?? NSNull(),
                                  "browser_download_url": url ?? "https://github.com/misswell/ClipNest/releases/download/v\(version)/ClipNest-\(version)-macos.zip"]
        return try JSONSerialization.data(withJSONObject: ["tag_name": "v\(version)", "draft": false,
                                                          "prerelease": prerelease, "body": "Fixes", "assets": [asset]])
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testNumericVersionsRejectDowngradesAndInvalidTags() throws {
        let release = try ClipNestUpdateRelease.decode(response(version: "1.10"))
        XCTAssertTrue(release.isNewer(than: "1.9"))
        XCTAssertFalse(release.isNewer(than: "1.10.0"))
        XCTAssertFalse(release.isNewer(than: "2.0"))
        XCTAssertFalse(release.isNewer(than: "bad"))
        for invalid in ["", "1..2", "1.6-beta.1", "1/6", "-1", "１.６", "1.2.3.4.5"] {
            XCTAssertNil(ClipNestUpdateVersion(invalid), invalid)
        }
    }
    func testReleaseRequiresStableTrustedAssetAndDigest() throws {
        for data in [try response(prerelease: true), try response(digest: nil), try response(digest: "sha256:bad"),
                     try response(url: "https://example.com/ClipNest.zip"), try response(size: 0),
                     try response(size: Int(ClipNestUpdateIdentity.maximumArchiveSize + 1)), try response(version: "1.6-beta")] {
            XCTAssertThrowsError(try ClipNestUpdateRelease.decode(data))
        }
    }
    func testHashAndCorruptArchiveAreRejectedBeforeExtraction() throws {
        let root = try directory()
        let archive = root.appendingPathComponent("update.zip")
        try Data("abc".utf8).write(to: archive)
        XCTAssertEqual(try ClipNestUpdatePackage.sha256(at: archive), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let release = try ClipNestUpdateRelease.decode(response(size: 3))
        XCTAssertThrowsError(try ClipNestUpdatePackage.unpack(archive, release: release, into: root)) { error in
            guard case ClipNestUpdateError.checksum = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClipNest.app").path))
    }
    func testUntrustedApplicationSignatureIsRejected() throws {
        XCTAssertThrowsError(try ClipNestUpdatePackage.verifySignature(try directory()))
    }
    func testEmbeddedInstallerSupportsCurrentProcessor() throws {
        let app = Bundle.main.bundleURL
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        for binary in [app.appendingPathComponent("Contents/MacOS/ClipNest"), ClipNestUpdateIdentity.helper(in: app)] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
            XCTAssertNoThrow(try ClipNestUpdatePackage.run("/usr/bin/lipo", [binary.path, "-verify_arch", architecture]))
        }
        // Development builds must reach the signature rejection after identity and
        // architecture checks, rather than fail earlier due to installer wiring.
        if (try? ClipNestUpdatePackage.verifySignature(app)) == nil {
            let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            XCTAssertThrowsError(try ClipNestUpdatePackage.validate(app, version: version, assessGatekeeper: false)) { error in
                guard case ClipNestUpdateError.signature = error else { return XCTFail("\(error)") }
            }
        }
    }
    func testSuccessfulInstallationKeepsNewAppAndRemovesBackup() throws {
        let root = try directory()
        let source = root.appendingPathComponent("new.app")
        let destination = root.appendingPathComponent("ClipNest.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("version"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("version"))
        try ClipNestUpdateInstallation.install(source: source, destination: destination,
            validate: { XCTAssertEqual(try Data(contentsOf: $0.appendingPathComponent("version")), Data("new".utf8)) },
            launch: { XCTAssertEqual(try Data(contentsOf: $0.appendingPathComponent("version")), Data("new".utf8)) },
            rollbackLaunch: { _ in XCTFail("Unexpected rollback") })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("version")), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["ClipNest.app", "new.app"])
    }
    func testFailedLaunchRestoresOldAppAndLaunchesIt() throws {
        let root = try directory()
        let source = root.appendingPathComponent("new.app")
        let destination = root.appendingPathComponent("ClipNest.app")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        var restored = false
        XCTAssertThrowsError(try ClipNestUpdateInstallation.install(source: source, destination: destination,
            validate: { _ in }, launch: { _ in throw ClipNestUpdateError.launchFailed },
            rollbackLaunch: { restored = true; XCTAssertEqual(try Data(contentsOf: $0), Data("old".utf8)) }))
        XCTAssertTrue(restored)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
    func testFailedValidationNeverTouchesInstalledApp() throws {
        let root = try directory()
        let source = root.appendingPathComponent("new.app")
        let destination = root.appendingPathComponent("ClipNest.app")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        XCTAssertThrowsError(try ClipNestUpdateInstallation.install(source: source, destination: destination,
            validate: { _ in throw ClipNestUpdateError.signature },
            launch: { _ in XCTFail("Unexpected launch") }, rollbackLaunch: { _ in XCTFail("Unexpected rollback") }))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    @MainActor
    func testCheckOffersNewerVersionButNeverAnOlderRelease() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UpdateTestProtocol.payload = try response()
        UpdateTestProtocol.status = 200
        let defaults = UserDefaults(suiteName: "UpdateTests-\(UUID().uuidString)")!
        let newer = SoftwareUpdate(session: session, defaults: defaults, currentVersion: "1.5")
        newer.check()
        while newer.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(newer.state, .available)
        XCTAssertEqual(newer.release?.version, "1.6")
        XCTAssertTrue(newer.showUpdate)
        let older = SoftwareUpdate(session: session, defaults: defaults, currentVersion: "2.0")
        older.check()
        while older.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(older.state, .current)
        XCTAssertNil(older.release)
    }
    @MainActor
    func testAvailableUpdateDialogRenders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UpdateTestProtocol.payload = try response()
        UpdateTestProtocol.status = 200
        let updater = SoftwareUpdate(session: session, currentVersion: "1.5")
        updater.check()
        while updater.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        let host = NSHostingView(rootView: SoftwareUpdateView(updater: updater).environmentObject(VaultStore()))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000)
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("clipnest-update-dialog.png"))
    }

    @MainActor
    func testServerErrorIsRecoverableAndDoesNotOfferInstallation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        UpdateTestProtocol.payload = Data()
        UpdateTestProtocol.status = 403
        let updater = SoftwareUpdate(session: session, currentVersion: "1.5")
        updater.check()
        while updater.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(updater.state, .failed)
        XCTAssertNotNil(updater.errorMessage)
        XCTAssertNil(updater.release)
    }
    @MainActor
    func testEditorWritesFinishBeforeUpdateCanQuit() async throws {
        let root = try directory()
        let note = root.appendingPathComponent("note.md")
        try "old".write(to: note, atomically: true, encoding: .utf8)
        let store = VaultStore()
        store.openVault(at: root)
        defer { store.closeVault() }
        store.save("latest edit", to: note)
        try await store.waitForEditorSaves()
        XCTAssertEqual(try String(contentsOf: note), "latest edit")
        try FileManager.default.removeItem(at: note)
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        store.save("cannot save", to: note)
        do { try await store.waitForEditorSaves(); XCTFail("Save failure must block update exit") }
        catch { }
    }
}

private final class UpdateTestProtocol: URLProtocol {
    static var payload = Data()
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { request.url == ClipNestUpdateIdentity.apiURL }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
