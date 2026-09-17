import Foundation
import CoreGraphics

/// The value the OCR layer produces: the joined text plus the individual lines Vision
/// returned, so downstream code can weigh confidence per line instead of trusting everything
/// equally (China plan §5, §31).
/// One recognized text line with its position and per-line confidence.
struct OCRTextBlock: Equatable, Sendable {
    let text: String
    let confidence: Float
    /// Normalized Vision coordinates (origin bottom-left, 0...1) so the value is
    /// resolution-independent and comparable across captures.
    let boundingBox: CGRect
}

struct OCRResult: Equatable, Sendable {
    let text: String
    let blocks: [OCRTextBlock]
    let confidence: Float

    static let empty = OCRResult(text: "", blocks: [], confidence: 0)

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
