import Foundation
import Security

enum GyazoTokenStoreError: LocalizedError {
    case missingAccessGroup
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .missingAccessGroup:
            return "Keychain共有設定を読み込めませんでした。"
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Gyazo TokenをKeychainへ保存できませんでした（\(message)）。"
        case .invalidData:
            return "Keychainに保存されたGyazo Tokenを読み込めませんでした。"
        }
    }
}

enum GyazoTokenStore {
    private static let service = "LogSense.Gyazo"
    private static let account = "access-token"
    private static let legacyDefaultsKey = "GyazoToken"
    private static let accessGroupInfoKey = "LogSenseKeychainAccessGroup"

    static func load(migratingFrom defaults: UserDefaults) -> String {
        if let token = try? read(), !token.isEmpty {
            return token
        }

        guard let legacyToken = defaults.string(forKey: legacyDefaultsKey),
              !legacyToken.isEmpty else {
            return ""
        }

        do {
            try save(legacyToken, removingLegacyValueFrom: defaults)
        } catch {
            // Keep the legacy value so the user can continue using image sharing
            // until Keychain access is available.
        }
        return legacyToken
    }

    static func save(_ token: String, removingLegacyValueFrom defaults: UserDefaults) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            try delete()
        } else {
            try upsert(token)
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    private static func read() throws -> String? {
        var query = try baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw GyazoTokenStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw GyazoTokenStoreError.invalidData
        }
        return token
    }

    private static func upsert(_ token: String) throws {
        let data = Data(token.utf8)
        let query = try baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GyazoTokenStoreError.unexpectedStatus(updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GyazoTokenStoreError.unexpectedStatus(addStatus)
        }
    }

    private static func delete() throws {
        let status = SecItemDelete(try baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GyazoTokenStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery() throws -> [String: Any] {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: accessGroupInfoKey) as? String,
              !accessGroup.isEmpty else {
            throw GyazoTokenStoreError.missingAccessGroup
        }

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}
