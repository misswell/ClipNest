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

    func accepts(_ request: Request) -> Bool {
        request.generation == generation && request.url == currentURL
    }
}
