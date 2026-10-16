import Foundation
import Security

protocol LinkedInTokenStore {
    func load() -> LinkedInToken?
    @discardableResult func save(_ token: LinkedInToken) -> Bool
    func clear()
    func clearAccountDeletionData()
}

extension LinkedInTokenStore {
    func clearAccountDeletionData() {
        clear()
    }
}

final class AuthTokenStore: LinkedInTokenStore {
    private let key: String
    private let service = "com.dailymind.bloomary.linkedin"

    init(key: String) {
        self.key = key
    }

    func load() -> LinkedInToken? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder.app.decode(LinkedInToken.self, from: data)
    }

    func save(_ token: LinkedInToken) -> Bool {
        guard let data = try? JSONEncoder.app.encode(token) else { return false }
        var query = keychainQuery
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    func clear() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    func clearAccountDeletionData() {
        clear()
        var synchronizableQuery = keychainQuery
        synchronizableQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(synchronizableQuery as CFDictionary)
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
