import Foundation
import Security

protocol SecureKeyValueStoring: AnyObject, Sendable {
    func set(_ value: Data, for key: String) throws
    func value(for key: String) throws -> Data?
    func deleteValue(for key: String) throws
}

final class KeychainStore: SecureKeyValueStoring, @unchecked Sendable {
    nonisolated static let shared = KeychainStore()

    private let service = AppConfiguration.shared.bundleID

    nonisolated func set(_ value: Data, for key: String) throws {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = value

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.unknown("Unable to save secure value for \(key).")
        }
    }

    nonisolated func value(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.unknown("Unable to read secure value for \(key).")
        }
    }

    nonisolated func deleteValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.unknown("Unable to delete secure value for \(key).")
        }
    }

    nonisolated private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
