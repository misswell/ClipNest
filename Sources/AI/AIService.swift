import Foundation

protocol AIProvider {
    func generateNote(from content: ClipboardContent,
                      existingCategories: [String],
                      preferredLanguage: PreferredLanguage) async throws -> GeneratedNote
}

protocol NoteGenerating {
    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote
}

enum AIServiceError: LocalizedError {
    case invalidConfiguration
    case invalidEndpoint
    case httpStatus(Int, String)
    case emptyResponse
    case invalidJSON
    case invalidNote(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return String(localized: "AI configuration is incomplete. Check the API key, base URL, and model.")
        case .invalidEndpoint:
            return String(localized: "The base URL is invalid. Enter an http:// or https:// address.")
        case let .httpStatus(status, message):
            return message.isEmpty ? String(localized: "The AI service returned HTTP \(status).") : String(localized: "The AI service returned HTTP \(status): \(message)")
        case .emptyResponse:
            return String(localized: "The AI returned no usable content.")
        case .invalidJSON:
            return String(localized: "The AI response is not valid structured JSON.")
        case let .invalidNote(message):
            return String(localized: "AI note is incomplete: \(message)")
        }
    }
}

struct AIService {
    private let provider: AIProvider

    init(configuration: AIConfiguration) {
        provider = OpenAICompatibleProvider(configuration: configuration)
    }

    func generateNote(from content: ClipboardContent,
                      existingCategories: [String],
                      preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        try await provider.generateNote(from: content,
                                        existingCategories: existingCategories,
                                        preferredLanguage: preferredLanguage)
    }
}

struct NoteGenerationService: NoteGenerating {
    private let aiService: AIService

    init(configuration: AIConfiguration) {
        aiService = AIService(configuration: configuration)
    }

    func generate(from content: ClipboardContent,
                  existingCategories: [String],
                  preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        try await aiService.generateNote(from: content,
                                          existingCategories: existingCategories,
                                          preferredLanguage: preferredLanguage)
    }
}
