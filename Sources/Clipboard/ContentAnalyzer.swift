import Foundation

/// Converts pasteboard text into the normalized content model. Keeping this separate leaves
/// room for image, PDF, HTML, and rich-text adapters without coupling them to the coordinator.
struct ContentAnalyzer {
    func analyze(_ rawText: String) -> ClipboardContent? {
        ClipboardContent(text: rawText)
    }
}
