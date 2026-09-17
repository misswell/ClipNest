import Foundation
import CoreGraphics
import Vision

/// Apple Vision text recognition, shared by iOS and macOS (spec §5).
///
/// This replaces the iOS-only photo path so a screenshot captured on the Mac goes through
/// exactly the same OCR code as one captured on the phone.
struct VisionOCRService: OCRRecognizing {
    /// Chinese first, then English: ClipNest content is usually Chinese prose carrying
    /// English technical terms, and Vision handles that pairing well.
    static let defaultLanguages = ["zh-Hans", "en-US"]

    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    var usesLanguageCorrection = true
    var languages: [String] = VisionOCRService.defaultLanguages
    /// Prefer the language the text actually is, when the OS reports it as supported.
    var usesAutomaticLanguageDetection = false

    func recognizeText(cgImage: CGImage, languages requestedLanguages: [String]) async throws -> OCRResult {
        let level = recognitionLevel
        let correction = usesLanguageCorrection
        let candidates = requestedLanguages.isEmpty ? languages : requestedLanguages
        let automatic = usesAutomaticLanguageDetection

        // Vision is synchronous and CPU-bound: keep it off the main actor (spec §38).
        return try await Task.detached(priority: .utility) {
            try Self.perform(cgImage: cgImage,
                             languages: candidates,
                             level: level,
                             usesLanguageCorrection: correction,
                             automaticLanguageDetection: automatic)
        }.value
    }

    private static func perform(cgImage: CGImage,
                                languages: [String],
                                level: VNRequestTextRecognitionLevel,
                                usesLanguageCorrection: Bool,
                                automaticLanguageDetection: Bool) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = usesLanguageCorrection
        request.recognitionLanguages = resolvedLanguages(preferred: languages,
                                                         revision: request.revision,
                                                         automatic: automaticLanguageDetection)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.recognitionFailed(error.localizedDescription)
        }

        var blocks: [OCRTextBlock] = []
        var confidences: [Float] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            blocks.append(OCRTextBlock(text: text,
                                       confidence: candidate.confidence,
                                       boundingBox: observation.boundingBox))
            confidences.append(candidate.confidence)
        }

        let text = blocks.map(\.text).joined(separator: "\n")
        let average = confidences.isEmpty
            ? 0
            : confidences.reduce(0, +) / Float(confidences.count)
        return OCRResult(text: text, blocks: blocks, confidence: average)
    }

    /// Intersects the requested languages with what this OS actually supports, so an
    /// unrecognized code never makes the request fail.
    static func resolvedLanguages(preferred: [String],
                                  revision: Int,
                                  automatic: Bool = false) -> [String] {
        let supported = supportedLanguages(forRevision: revision)
        guard !supported.isEmpty else { return preferred }

        if automatic {
            // Vision's own language detection is driven by the fixture order; leading with
            // the user's languages plus everything supported keeps it broad but safe.
            let ordered = (preferred + supported).reduce(into: [String]()) { result, language in
                guard supported.contains(language), !result.contains(language) else { return }
                result.append(language)
            }
            return ordered.isEmpty ? supported : ordered
        }

        let available = preferred.filter { supported.contains($0) }
        return available.isEmpty ? supported : available
    }

    /// Supported languages, for the Settings capability readout.
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// Supported languages for a specific request revision.
    ///
    /// Uses the instance `supportedRecognitionLanguages()`; the older
    /// `supportedRecognitionLanguages(for:revision:)` class method is deprecated as of
    /// macOS 12 / iOS 15.
    static func supportedLanguages(forRevision revision: Int) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = revision
        return (try? request.supportedRecognitionLanguages()) ?? []
    }
}

/// Backwards-compatible shim for the original iOS-only entry point. New code should use
/// `VisionOCRService` through `OCRRecognizing`.
enum PhotoCaptureService {
    /// OCR with Chinese + English recognition. Returns "" when nothing readable is found.
    static func recognizeText(in image: PlatformImage) throws -> String {
        guard let cgImage = image.ocrCGImage else { return "" }
        let result = try VisionOCRService().recognizeTextSync(cgImage: cgImage)
        return result.text
    }
}

extension VisionOCRService {
    /// Blocking variant used by the synchronous shim above; still off the main thread when
    /// called from `Task.detached`.
    func recognizeTextSync(cgImage: CGImage, languages requestedLanguages: [String] = []) throws -> OCRResult {
        try Self.perform(cgImage: cgImage,
                         languages: requestedLanguages.isEmpty ? languages : requestedLanguages,
                         level: recognitionLevel,
                         usesLanguageCorrection: usesLanguageCorrection,
                         automaticLanguageDetection: usesAutomaticLanguageDetection)
    }
}
