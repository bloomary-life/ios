import Foundation
import Security

struct AISettings {
    let apiKey: String
    var postLanguage: String = PostLanguage.english
}

enum PostLanguage {
    static let english = "English"
    static let sameAsDraft = "same"
    static let all = ["English", "German", "Spanish", "French", "Portuguese", "Italian", "Dutch", "Polish",
                      "Ukrainian", "Russian", "Greek", "Turkish", "Arabic", "Hindi", sameAsDraft]

    static func label(_ value: String) -> String { value == sameAsDraft ? "Same as my draft" : value }
}

protocol AIAPIKeyStore {
    func load() -> String?
    func save(_ apiKey: String) -> Bool
    func clear() -> Bool
}

@MainActor
final class AISettingsStore: ObservableObject {
    @Published var apiKey: String
    @Published private(set) var statusMessage: String?
    @Published var postLanguage: String {
        didSet { defaults.set(postLanguage, forKey: Self.postLanguageKey) }
    }

    private let keyStore: AIAPIKeyStore
    private let defaults: UserDefaults
    private static let postLanguageKey = "ai-post-language"

    init(keyStore: AIAPIKeyStore = KeychainAIAPIKeyStore(), defaults: UserDefaults = .standard) {
        self.keyStore = keyStore
        self.defaults = defaults
        self.apiKey = keyStore.load() ?? ""
        self.postLanguage = defaults.string(forKey: Self.postLanguageKey) ?? PostLanguage.english
    }

    var current: AISettings {
        AISettings(apiKey: apiKey, postLanguage: postLanguage)
    }

    func save() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmedKey
        let saved: Bool
        if trimmedKey.isEmpty {
            saved = keyStore.clear()
        } else {
            saved = keyStore.save(trimmedKey)
        }
        statusMessage = saved ? "AI settings saved." : "AI key could not be saved."
    }

    @discardableResult
    func clearAPIKey() -> Bool {
        guard keyStore.clear() else {
            statusMessage = "AI key could not be deleted. Unlock this device and try again."
            return false
        }
        apiKey = ""
        statusMessage = "AI key cleared."
        return true
    }

    @discardableResult
    func clearAccountDeletionData() -> Bool {
        clearAPIKey()
    }
}

final class KeychainAIAPIKeyStore: AIAPIKeyStore {
    private let key = "ai-api-key"
    private let service: String

    init(service: String = "com.dailymind.bloomary.ai") { self.service = service }

    func load() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ apiKey: String) -> Bool {
        guard let data = apiKey.data(using: .utf8) else { return false }
        var query = keychainQuery
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    func clear() -> Bool {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        var synchronizableQuery = keychainQuery
        synchronizableQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let syncStatus = SecItemDelete(synchronizableQuery as CFDictionary)
        return (status == errSecSuccess || status == errSecItemNotFound) &&
            (syncStatus == errSecSuccess || syncStatus == errSecItemNotFound)
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
