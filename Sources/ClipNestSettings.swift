import Foundation

/// UserDefaults and Keychain identifiers shared by the capture pipeline and Settings.
/// Keeping them in one place prevents the UI and background capture task from drifting apart.
enum ClipNestSettings {
    static let autoDetectClipboard = "capture.autoDetectClipboard"
    static let autoGenerateNote = "capture.autoGenerateNote"
    static let processingMode = "capture.processingMode"

    static let aiBaseURL = "ai.baseURL"
    static let aiModel = "ai.model"
    static let aiPreferredLanguage = "ai.preferredLanguage"

    static let autoClassify = "classification.autoClassify"
    static let allowNewCategories = "classification.allowNewCategories"
    static let defaultCategory = "classification.defaultCategory"

    static let lastClipboardHash = "capture.lastClipboardHash"
    static let lastSeenClipboardHash = "capture.lastSeenClipboardHash"
    static let lastClipboardChangeCount = "capture.lastClipboardChangeCount"
    static let lastAttemptedClipboardHash = "capture.lastAttemptedClipboardHash"

    static let keychainService = "com.tertiaryinfotech.clipnest"
    static let keychainAccount = "openai-compatible-api-key"
}

enum ClipboardProcessingMode: String, CaseIterable, Identifiable {
    case automatic
    case confirmBeforeSave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .confirmBeforeSave: return String(localized: "Confirm before saving")
        }
    }

    var description: String {
        switch self {
        case .automatic: return String(localized: "Analyze, classify, and write straight into the vault")
        case .confirmBeforeSave: return String(localized: "Preview first, edit before saving")
        }
    }
}

enum PreferredLanguage: String, CaseIterable, Identifiable {
    case automatic
    case simplifiedChinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Match content")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}
