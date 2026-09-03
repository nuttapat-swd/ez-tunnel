import Foundation
import Security
import EZTunnelCore

struct KeychainSSHCredentialStore: SSHCredentialStore {
    private let service = "dev.nuttapat.ez-tunnel.ssh-credential"

    func credential(for key: SSHCredentialKey) throws -> String? {
        if let credential = try credential(matching: baseQuery(for: key)) {
            return credential
        }

        // Older versions used the profile UUID as an untyped account. The
        // caller requests the kind selected by the saved authentication method,
        // so migrate that item into exactly one typed account on first access.
        let legacyQuery = legacyBaseQuery(for: key.profileID)
        guard let legacyCredential = try credential(matching: legacyQuery) else {
            return nil
        }
        try setCredential(legacyCredential, for: key)
        let status = SecItemDelete(legacyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
        return legacyCredential
    }

    private func credential(matching baseQuery: [String: Any]) throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func setCredential(_ credential: String, for key: SSHCredentialKey) throws {
        let data = Data(credential.utf8)
        let query = baseQuery(for: key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func removeCredential(for key: SSHCredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for key: SSHCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(key.profileID.uuidString):\(key.kind.rawValue)",
        ]
    }

    private func legacyBaseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain operation failed (\(status))."
    }
}
