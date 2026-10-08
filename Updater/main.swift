import AppKit
import Foundation

// This executable is copied out of the bundle before the parent exits. It never
// needs elevated privileges and keeps the old app until the new process is healthy.
func launch(_ app: URL) throws {
    var launched: NSRunningApplication?
    let semaphore = DispatchSemaphore(value: 0)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, _ in
        launched = running
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(20)
    while semaphore.wait(timeout: .now()) != .success && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard let running = launched, !running.isTerminated,
          running.bundleURL?.standardizedFileURL == app.standardizedFileURL else {
        if launched?.bundleURL?.standardizedFileURL == app.standardizedFileURL { launched?.forceTerminate() }
        throw ClipNestUpdateError.launchFailed
    }
    let observationEnd = Date().addingTimeInterval(2)
    while Date() < observationEnd {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if running.isTerminated { throw ClipNestUpdateError.launchFailed }
    }
}

let arguments = CommandLine.arguments
var failureMarker: URL?
var staging: URL?
var recoveryApplication: URL?
var recoveryVersion: String?
var parentExited = false
do {
    guard arguments.count == 7, let parentPID = Int32(arguments[1]), parentPID > 0 else {
        throw ClipNestUpdateError.invalidApplication
    }
    let source = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let destination = URL(fileURLWithPath: arguments[3]).standardizedFileURL
    let version = arguments[4]
    let workspace = URL(fileURLWithPath: arguments[5]).standardizedFileURL
    let marker = URL(fileURLWithPath: arguments[6]).standardizedFileURL
    // The source and this copied helper must belong to the same private workspace.
    let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    guard workspace.lastPathComponent.hasPrefix("ClipNest-update-"),
          workspace.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
          source == workspace.appendingPathComponent("package/ClipNest.app"),
          executable.deletingLastPathComponent() == workspace.appendingPathComponent("installer"),
          destination.pathExtension == "app", !destination.path.hasPrefix(workspace.path + "/"),
          destination.resolvingSymlinksInPath() == destination,
          let next = ClipNestUpdateVersion(version),
          let currentString = try ClipNestUpdatePackage.info(at: destination)["CFBundleShortVersionString"] as? String,
          let current = ClipNestUpdateVersion(currentString), next > current else {
        throw ClipNestUpdateError.invalidApplication
    }
    failureMarker = marker
    staging = workspace
    try ClipNestUpdatePackage.verifySignature(destination)
    recoveryApplication = destination
    recoveryVersion = currentString
    let deadline = Date().addingTimeInterval(30)
    while kill(parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    guard kill(parentPID, 0) != 0 else { throw ClipNestUpdateError.parentRunning }
    parentExited = true
    // Reject a second instance that may still be editing notes or holding resources.
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: ClipNestUpdateIdentity.bundleID)
        .contains(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == destination }) else {
        throw ClipNestUpdateError.parentRunning
    }
    try ClipNestUpdatePackage.validate(source, version: version)
    try ClipNestUpdateInstallation.install(source: source, destination: destination,
        validate: { try ClipNestUpdatePackage.validate($0, version: version) },
        launch: launch, rollbackLaunch: { _ in })
    try? FileManager.default.removeItem(at: marker)
} catch {
    if let failureMarker {
        try? FileManager.default.createDirectory(at: failureMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A stable code is localized by the app on its next launch.
        let message: String
        if case ClipNestUpdateError.rollbackFailed(let backup) = error { message = "backup:" + backup }
        else { message = "failed" }
        try? Data(message.utf8).write(to: failureMarker, options: .atomic)
    }
    fputs("ClipNest updater: \(error.localizedDescription)\n", stderr)
    if parentExited, let app = recoveryApplication,
       FileManager.default.fileExists(atPath: app.path),
       (try? ClipNestUpdatePackage.info(at: app)["CFBundleShortVersionString"] as? String) == recoveryVersion,
       !NSRunningApplication.runningApplications(withBundleIdentifier: ClipNestUpdateIdentity.bundleID)
        .contains(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == app }) {
        try? launch(app)
    }
}
if let staging { try? FileManager.default.removeItem(at: staging) }
