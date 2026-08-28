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
            return "AI 配置不完整，请检查 API Key、Base URL 和模型。"
        case .invalidEndpoint:
            return "Base URL 无效，请输入 http:// 或 https:// 地址。"
        case let .httpStatus(status, message):
            return message.isEmpty ? "AI 服务返回 HTTP \(status)。" : "AI 服务返回 HTTP \(status)：\(message)"
        case .emptyResponse:
            return "AI 没有返回可用内容。"
        case .invalidJSON:
            return "AI 返回的内容不是有效的结构化 JSON。"
        case let .invalidNote(message):
            return "AI 笔记内容不完整：\(message)"
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
