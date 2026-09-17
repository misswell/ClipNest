import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Text recognition contract. Apple Vision is the only implementation (spec §4) — no
/// third-party OCR model is bundled, because every ClipNest target is an Apple platform.
protocol OCRRecognizing: Sendable {
    func recognizeText(cgImage: CGImage, languages: [String]) async throws -> OCRResult
}

enum OCRError: LocalizedError {
    case noImage
    case noSupportedLanguages
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImage:
            return String(localized: "That image could not be read.")
        case .noSupportedLanguages:
            return String(localized: "No text recognition languages are installed on this device.")
        case let .recognitionFailed(message):
            return String(localized: "Text recognition failed: \(message)")
        }
    }
}

extension PlatformImage {
    /// The `CGImage` backing this image, on either platform.
    var ocrCGImage: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #elseif canImport(AppKit)
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }
}
