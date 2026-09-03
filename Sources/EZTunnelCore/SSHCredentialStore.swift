import Foundation

public protocol SSHCredentialStore {
    func credential(for profileID: UUID) throws -> String?
    func setCredential(_ credential: String, for profileID: UUID) throws
    func removeCredential(for profileID: UUID) throws
}

public struct UnavailableSSHCredentialStore: SSHCredentialStore, Sendable {
    public init() {}
    public func credential(for profileID: UUID) throws -> String? { nil }
    public func setCredential(_ credential: String, for profileID: UUID) throws {
        throw CocoaError(.featureUnsupported)
    }
    public func removeCredential(for profileID: UUID) throws {}
}
