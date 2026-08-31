import Foundation

enum CaptureState: String, Equatable {
    case idle
    case detecting
    case analyzing
    case generating
    case classifying
    case saving
    case completed
    case failed

    var title: String {
        switch self {
        case .idle: return String(localized: "Waiting for clipboard")
        case .detecting: return String(localized: "Detecting clipboard")
        case .analyzing: return String(localized: "Analyzing content")
        case .generating: return String(localized: "Generating note")
        case .classifying: return String(localized: "Classifying")
        case .saving: return String(localized: "Saving note")
        case .completed: return String(localized: "Done")
        case .failed: return String(localized: "Capture failed")
        }
    }

    var isProcessing: Bool {
        switch self {
        case .detecting, .analyzing, .generating, .classifying, .saving:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}
