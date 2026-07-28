import Foundation
import Security

protocol APIKeyStoring { func save(_ value: String) throws; func read() throws -> String?; func delete() throws }
enum KeychainError: Error { case status(OSStatus), encoding }
final class KeychainAPIKeyStore: APIKeyStoring {
    private let service = "com.fkw16.dcatracker.twelvedata", account = "api-key"
    func save(_ value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil); guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
    func read() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainError.encoding }; return value
    }
    func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
