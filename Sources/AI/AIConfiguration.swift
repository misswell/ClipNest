import Foundation
import Security

struct AIConfiguration: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String
    var preferredLanguage: PreferredLanguage

    static let `default` = AIConfiguration(
        baseURL: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o-mini",
        preferredLanguage: .automatic
    )

    var isValid: Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return false }
        return true
    }
}

/// Endpoint used for photo captures. When `usesSeparateEndpoint` is false the text
/// model configuration is reused and photos are processed as recognized text only.
struct AIImageConfiguration: Equatable {
    var usesSeparateEndpoint: Bool
    var baseURL: String
    var apiKey: String
    var model: String

    var isValid: Bool {
        AIConfiguration(baseURL: baseURL, apiKey: apiKey, model: model, preferredLanguage: .automatic).isValid
    }
}

enum AIConfigurationStore {
    /// Default is `local` (China plan §8): a fresh install is private and offline-capable.
    ///
    /// An unrecognised stored value also resolves to `local`. That covers an install upgrading
    /// from the earlier three-mode build, where `automatic` was persisted: preferring the
    /// device is the safe reading of that preference, since the alternative would silently
    /// send content to a network the user may no longer expect to be used.
    static func loadProcessingMode() -> AIProcessingMode {
        let raw = UserDefaults.standard.string(forKey: ClipNestSettings.aiProcessingMode)
            ?? AIProcessingMode.recommended.rawValue
        return AIProcessingMode(rawValue: raw) ?? .recommended
    }

    static func saveProcessingMode(_ mode: AIProcessingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ClipNestSettings.aiProcessingMode)
    }

    static func loadLocalSemanticSearchEnabled() -> Bool {
        UserDefaults.standard.object(forKey: ClipNestSettings.localSemanticSearch) as? Bool ?? true
    }

    /// §25: Qwen widens a search query with related keywords. On by default, and a no-op
    /// unless a model is installed, so it costs nothing on a fresh install.
    static func loadLocalQueryExpansionEnabled() -> Bool {
        UserDefaults.standard.object(forKey: ClipNestSettings.localQueryExpansion) as? Bool ?? true
    }

    static func saveLocalQueryExpansionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ClipNestSettings.localQueryExpansion)
    }

    static func load() -> AIConfiguration {
        let defaults = UserDefaults.standard
        let languageRaw = defaults.string(forKey: ClipNestSettings.aiPreferredLanguage)
            ?? PreferredLanguage.automatic.rawValue
        return AIConfiguration(
            baseURL: defaults.string(forKey: ClipNestSettings.aiBaseURL)
                ?? AIConfiguration.default.baseURL,
            apiKey: KeychainStore.read(service: ClipNestSettings.keychainService,
                                        account: ClipNestSettings.keychainAccount) ?? "",
            model: defaults.string(forKey: ClipNestSettings.aiModel)
                ?? AIConfiguration.default.model,
            preferredLanguage: PreferredLanguage(rawValue: languageRaw) ?? .automatic
        )
    }

    static func save(_ configuration: AIConfiguration) {
        let defaults = UserDefaults.standard
        defaults.set(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: ClipNestSettings.aiBaseURL)
        defaults.set(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: ClipNestSettings.aiModel)
        defaults.set(configuration.preferredLanguage.rawValue,
                     forKey: ClipNestSettings.aiPreferredLanguage)
        saveAPIKey(configuration.apiKey)
    }

    // MARK: - Image model (photo captures)

    static func loadImageConfiguration() -> AIImageConfiguration {
        let defaults = UserDefaults.standard
        return AIImageConfiguration(
            usesSeparateEndpoint: defaults.bool(forKey: ClipNestSettings.aiImageSeparateEndpoint),
            baseURL: defaults.string(forKey: ClipNestSettings.aiImageBaseURL)
                ?? AIConfiguration.default.baseURL,
            apiKey: KeychainStore.read(service: ClipNestSettings.keychainService,
                                        account: ClipNestSettings.aiImageKeychainAccount) ?? "",
            model: defaults.string(forKey: ClipNestSettings.aiImageModel) ?? ""
        )
    }

    static func saveImageConfiguration(_ configuration: AIImageConfiguration) {
        let defaults = UserDefaults.standard
        defaults.set(configuration.usesSeparateEndpoint,
                     forKey: ClipNestSettings.aiImageSeparateEndpoint)
        defaults.set(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: ClipNestSettings.aiImageBaseURL)
        defaults.set(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: ClipNestSettings.aiImageModel)
        let value = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            KeychainStore.delete(service: ClipNestSettings.keychainService,
                                  account: ClipNestSettings.aiImageKeychainAccount)
        } else {
            _ = KeychainStore.save(value,
                                   service: ClipNestSettings.keychainService,
                                   account: ClipNestSettings.aiImageKeychainAccount)
        }
    }

    static func saveAPIKey(_ apiKey: String) {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            KeychainStore.delete(service: ClipNestSettings.keychainService,
                                  account: ClipNestSettings.keychainAccount)
        } else {
            _ = KeychainStore.save(value,
                                   service: ClipNestSettings.keychainService,
                                   account: ClipNestSettings.keychainAccount)
        }
    }
}

private enum KeychainStore {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
