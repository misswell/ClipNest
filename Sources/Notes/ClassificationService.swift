import Foundation

struct ClassificationConfiguration {
    let automaticallyClassify: Bool
    let allowCreatingNewCategories: Bool
    let defaultCategory: String

    static func load() -> ClassificationConfiguration {
        let defaults = UserDefaults.standard
        return ClassificationConfiguration(
            automaticallyClassify: defaults.object(forKey: ClipNestSettings.autoClassify) as? Bool ?? true,
            allowCreatingNewCategories: defaults.object(forKey: ClipNestSettings.allowNewCategories) as? Bool ?? false,
            defaultCategory: defaults.string(forKey: ClipNestSettings.defaultCategory) ?? "Inbox"
        )
    }
}

/// Resolves the model's category suggestion against the user's real top-level folders.
/// Existing names always win; new folders are opt-in and capped to avoid AI-created folder drift.
struct ClassificationService {
    static let inbox = "Inbox"
    static let maximumAutomaticallyCreatedCategories = 20

    func classify(note: GeneratedNote,
                  existingCategories: [String],
                  configuration: ClassificationConfiguration) -> String {
        if let existing = exactMatch(configuration.automaticallyClassify ? note.category : "",
                                      in: existingCategories) {
            return existing
        }

        if let fallback = exactMatch(configuration.defaultCategory, in: existingCategories) {
            return fallback
        }

        let normalizedDefault = FileNameSanitizer.directoryName(from: configuration.defaultCategory,
                                                                  fallback: Self.inbox)
        if !configuration.automaticallyClassify {
            return normalizedDefault == Self.inbox ? Self.inbox : normalizedDefault
        }

        let proposed = FileNameSanitizer.directoryName(from: note.category, fallback: "")
        let canCreate = configuration.allowCreatingNewCategories
            && existingCategories.filter({ $0.caseInsensitiveCompare(Self.inbox) != .orderedSame }).count
                < Self.maximumAutomaticallyCreatedCategories
            && !proposed.isEmpty
            && proposed.caseInsensitiveCompare(Self.inbox) != .orderedSame

        return canCreate ? proposed : Self.inbox
    }

    private func exactMatch(_ value: String, in candidates: [String]) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = categoryKey(trimmed)
        return candidates.first {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame || categoryKey($0) == key
        }
    }

    private func categoryKey(_ value: String) -> String {
        var key = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        let genericSuffixes = ["开发", "技术", "知识", "笔记", "资料"]
        for suffix in genericSuffixes where key.hasSuffix(suffix) && key.count > suffix.count {
            key = String(key.dropLast(suffix.count))
            break
        }
        return key
    }
}
