import Foundation

/// Reserved URL adapter. MVP deliberately sends the URL itself to the provider; a future
/// implementation can fetch and clean article text without changing the capture coordinator.
protocol WebContentExtractor {
    func extractText(from url: URL) async throws -> String
}
