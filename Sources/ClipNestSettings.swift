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
    static let aiImageSeparateEndpoint = "ai.image.separateEndpoint"
    static let aiImageBaseURL = "ai.image.baseURL"
    static let aiImageModel = "ai.image.model"

    /// How content is organized: local or online (China plan §8, §16).
    static let aiProcessingMode = "ai.processingMode"
    /// Hybrid (keyword + semantic) vault search on by default.
    static let localSemanticSearch = "ai.localSemanticSearch"
    /// Version of the downloadable local model currently installed (China plan §32).
    static let localModelInstalledVersion = "ai.localModelInstalledVersion"
    /// When the local model was last used, for the Settings readout (China plan §32).
    static let localModelLastUsedAt = "ai.localModelLastUsedAt"

    /// Warm the on-device model as soon as the app is active, so the first capture does not pay
    /// the load. Off means the weights are read on first use instead (§26 either way: memory
    /// pressure and backgrounding still unload them).
    static let localModelPreload = "ai.localModelPreload"

    /// How the note body is produced — see `LocalBodyStyle`.
    static let localBodyStyle = "ai.localBodyStyle"
    /// The CDN serving `model-manifest.json` (China plan §4). Deliberately not a path:
    /// model locations are computed at runtime, never persisted (China plan §32).
    static let localModelManifestURL = "ai.localModelManifestURL"
    /// Let the local model expand a search query into keywords (China plan §25).
    static let localQueryExpansion = "ai.localQueryExpansion"
    /// Smart (hybrid) vs exact (keyword-only) search, spec §44.
    static let searchMode = "search.mode"
    /// How many recent note titles per category feed a category's semantic profile.
    static let localCategoryProfileSampleLimit = "ai.localCategoryProfileLimit"

    static let autoClassify = "classification.autoClassify"
    static let allowNewCategories = "classification.allowNewCategories"
    static let defaultCategory = "classification.defaultCategory"

    static let lastClipboardHash = "capture.lastClipboardHash"
    static let lastSeenClipboardHash = "capture.lastSeenClipboardHash"
    static let lastClipboardChangeCount = "capture.lastClipboardChangeCount"
    static let lastAttemptedClipboardHash = "capture.lastAttemptedClipboardHash"

    static let keychainService = "com.tertiaryinfotech.clipnest"
    static let keychainAccount = "openai-compatible-api-key"
    static let aiImageKeychainAccount = "openai-compatible-image-api-key"
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

/// How the vault search field interprets a query (spec §44). Technical vocabulary
/// ("embedding", "cosine similarity") is deliberately absent from the user-facing strings.
enum VaultSearchMode: String, CaseIterable, Identifiable {
    case smart
    case exact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return String(localized: "Smart Search")
        case .exact: return String(localized: "Exact Search")
        }
    }

    var description: String {
        switch self {
        case .smart:
            return String(localized: "Finds notes by meaning as well as by wording.")
        case .exact:
            return String(localized: "Matches the words you type, exactly as written.")
        }
    }
}
