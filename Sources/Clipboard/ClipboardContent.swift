import Foundation
import CryptoKit

enum ClipboardContentKind: String, Codable, CaseIterable, Identifiable {
    case plainText = "plain_text"
    case url = "url"
    case textAndURL = "text_and_url"
    // Reserved for the next capture adapters. MVP intentionally remains text-first.
    case image
    case pdf
    case richText = "rich_text"
    case html

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainText: return String(localized: "Text")
        case .url: return String(localized: "Link")
        case .textAndURL: return String(localized: "Text & Link")
        case .image: return String(localized: "Image")
        case .pdf: return "PDF"
        case .richText: return String(localized: "Rich Text")
        case .html: return "HTML"
        }
    }
}

/// A normalized, text-first representation of the pasteboard.
/// Image/PDF/HTML cases can be added later without changing the capture pipeline API.
struct ClipboardContent: Equatable {
    let rawText: String
    let text: String
    let kind: ClipboardContentKind
    let sourceURL: URL?

    init?(text rawText: String) {
        let normalized = Self.normalize(rawText)
        guard !normalized.isEmpty else { return nil }

        let urls = Self.detectURLs(in: normalized)
        let isURLOnly = urls.count == 1 && Self.isFullRange(urls[0].range, in: normalized)
        self.rawText = rawText
        self.text = normalized
        self.sourceURL = urls.first?.url
        self.kind = isURLOnly ? .url : (urls.isEmpty ? .plainText : .textAndURL)
    }

    static func normalize(_ rawText: String) -> String {
        rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    static func hash(for rawText: String) -> String {
        let data = Data(normalize(rawText).utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func detectURLs(in text: String) -> [(url: URL, range: NSRange)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let url = match.url else { return nil }
            return (url, match.range)
        }
    }

    private static func isFullRange(_ range: NSRange, in text: String) -> Bool {
        range.location == 0 && range.length == (text as NSString).length
    }
}

struct ClipboardSnapshot: Equatable {
    let content: ClipboardContent
    let changeCount: Int
    let hash: String
}
