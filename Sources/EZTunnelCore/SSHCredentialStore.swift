import Foundation

public enum SSHCredentialKind: String, CaseIterable, Sendable {
    case password
    case privateKeyPassphrase
}

extension SSHAuthenticationMethod {
    var credentialKind: SSHCredentialKind? {
        switch self {
        case .systemDefault: nil
        case .privateKey: .privateKeyPassphrase
        case .password: .password
        }
    }
}

public struct SSHCredentialKey: Hashable, Sendable {
    public let profileID: UUID
    public let kind: SSHCredentialKind

    public init(profileID: UUID, kind: SSHCredentialKind) {
        self.profileID = profileID
        self.kind = kind
    }
}

public protocol SSHCredentialStore {
    func credential(for key: SSHCredentialKey) throws -> String?
    func setCredential(_ credential: String, for key: SSHCredentialKey) throws
    func removeCredential(for key: SSHCredentialKey) throws
}

public struct UnavailableSSHCredentialStore: SSHCredentialStore, Sendable {
    public init() {}
    public func credential(for key: SSHCredentialKey) throws -> String? { nil }
    public func setCredential(_ credential: String, for key: SSHCredentialKey) throws {
        throw CocoaError(.featureUnsupported)
    }
    public func removeCredential(for key: SSHCredentialKey) throws {}
}
