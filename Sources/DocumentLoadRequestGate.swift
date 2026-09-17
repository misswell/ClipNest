import Foundation

/// Identifies the one document read that is currently allowed to update editor state.
///
/// File reads may outlive the SwiftUI task that started them (notably while an iCloud file is
/// downloading). A monotonically increasing generation prevents an older read from overwriting
/// the result of a newer selection when those reads finish out of order.
struct DocumentLoadRequestGate {
    struct Request: Equatable {
        fileprivate let generation: UInt64
        fileprivate let url: URL
    }

    private var generation: UInt64 = 0
    private var currentURL: URL?

    mutating func begin(for url: URL) -> Request {
        generation &+= 1
        let standardizedURL = url.standardizedFileURL
        currentURL = standardizedURL
        return Request(generation: generation, url: standardizedURL)
    }

    /// Begins a load only if the caller still owns its SwiftUI `.task`, returning `nil` otherwise.
    ///
    /// Cancellation is cooperative, so a `.task` that SwiftUI cancels before it ever runs **still
    /// executes its body**. If that abandoned task were allowed to call `begin`, it would bump the
    /// generation *after* the live task's, win the gate, and then load the document the user just
    /// navigated away from. The result is not a wrong note on screen but a spinner that never ends:
    /// `loadState` becomes `.ready` while `loadedURL` still names the abandoned document, so the
    /// "is this document ready" check can never be satisfied.
    ///
    /// Folding the check into `begin` rather than the two callers keeps the invariant in one place.
    mutating func begin(for url: URL, isCancelled: Bool) -> Request? {
        guard !isCancelled else { return nil }
        return begin(for: url)
    }

    func accepts(_ request: Request) -> Bool {
        request.generation == generation && request.url == currentURL
    }

    /// The document the gate currently expects. Exposed for tests and diagnostics.
    var currentDocumentURL: URL? { currentURL }
}
