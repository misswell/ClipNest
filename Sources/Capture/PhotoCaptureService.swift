#if os(iOS)
import Foundation
import UIKit
import Vision

/// On-device OCR for the capture pipeline. The photo itself arrives through the system
/// picker (PHPickerViewController — out-of-process, no photo-library permission needed);
/// only the recognized text enters the note pipeline.
enum PhotoCaptureService {
    /// OCR with Chinese + English recognition. Returns "" when nothing readable is found.
    static func recognizeText(in image: UIImage) throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: request.revision)) ?? ["en-US"]
        request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
        if request.recognitionLanguages.isEmpty {
            request.recognitionLanguages = supported
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }
}
#endif
