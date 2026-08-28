import Foundation

struct OpenAICompatibleProvider: AIProvider {
    let configuration: AIConfiguration
    private let session: URLSession

    init(configuration: AIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func generateNote(from content: ClipboardContent,
                      existingCategories: [String],
                      preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
        guard configuration.isValid else { throw AIServiceError.invalidConfiguration }
        guard let endpoint = makeEndpoint(from: configuration.baseURL) else {
            throw AIServiceError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionRequest(
            model: configuration.model,
            messages: [
                .init(role: "system",
                      content: NotePromptBuilder.systemPrompt(
                        existingCategories: existingCategories,
                        preferredLanguage: preferredLanguage)),
                .init(role: "user", content: NotePromptBuilder.userPrompt(for: content))
            ],
            temperature: 0.2,
            responseFormat: .init(type: "json_object")
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.httpStatus(-1, "AI 服务返回了无效响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIServiceError.httpStatus(httpResponse.statusCode, apiErrorMessage(from: data))
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw AIServiceError.invalidJSON
        }
        guard let rawContent = decoded.choices.first?.message.content,
              !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIServiceError.emptyResponse }

        // Deliberately decode the provider's complete response. We do not strip Markdown
        // fences or substring-search JSON, so malformed provider output fails safely.
        guard let jsonData = rawContent.data(using: .utf8) else {
            throw AIServiceError.invalidJSON
        }
        let payload: GeneratedNotePayload
        do {
            payload = try JSONDecoder().decode(GeneratedNotePayload.self, from: jsonData)
        } catch {
            throw AIServiceError.invalidJSON
        }
        return try payload.makeNote()
    }

    private func makeEndpoint(from rawBaseURL: String) -> URL? {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return nil }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("chat/completions") {
            if path.isEmpty { url.appendPathComponent("v1") }
            url.appendPathComponent("chat/completions")
        }
        return url
    }

    private func apiErrorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(240).description ?? ""
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        struct ContentPart: Decodable {
            let text: String?
        }

        let content: String?

        enum CodingKeys: String, CodingKey { case content }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try container.decodeIfPresent(String.self, forKey: .content) {
                content = string
            } else if let parts = try container.decodeIfPresent([ContentPart].self, forKey: .content) {
                content = parts.compactMap(\.text).joined()
            } else {
                content = nil
            }
        }
    }

    let choices: [Choice]
}

private struct GeneratedNotePayload: Decodable {
    let title: String?
    let summary: String?
    let content: String?
    let category: String?
    let tags: [String]?
    let sourceURL: String?

    func makeNote() throws -> GeneratedNote {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw AIServiceError.invalidNote("缺少标题") }
        guard !content.isEmpty else { throw AIServiceError.invalidNote("缺少正文") }

        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tags = (tags ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sourceURL = sourceURL.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return GeneratedNote(title: title,
                             summary: summary,
                             content: content,
                             category: category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                             tags: Array(NSOrderedSet(array: tags)) as? [String] ?? tags,
                             sourceURL: sourceURL)
    }
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}
