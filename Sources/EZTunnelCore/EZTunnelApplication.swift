import Foundation

public enum ProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case immutableLocalForwardChanged
    case duplicateTunnelProfileID(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Profile schema version \(version) is not supported."
        case .immutableLocalForwardChanged:
            "A saved Local Forward's identity and name cannot be changed."
        case .duplicateTunnelProfileID(let id):
            "Tunnel Profile identity \(id.uuidString) appears more than once."
        }
    }
}

@MainActor
public final class EZTunnelApplication {
    public private(set) var profiles: [TunnelProfile]

    private let persistence: any ProfilePersistence
    private let credentialStore: any SSHCredentialStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        persistence: any ProfilePersistence,
        credentialStore: any SSHCredentialStore = UnavailableSSHCredentialStore()
    ) throws {
        self.persistence = persistence
        self.credentialStore = credentialStore
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try persistence.load() else {
            self.profiles = []
            return
        }
        let header = try decoder.decode(ProfileDocumentHeader.self, from: data)
        let loadedProfiles: [TunnelProfile]
        switch header.schemaVersion {
        case 1:
            loadedProfiles = try decoder.decode(LegacyProfileDocument.self, from: data)
                .profiles.map { try $0.migrated() }
        case 2:
            loadedProfiles = try decoder.decode(LegacyVersionTwoProfileDocument.self, from: data)
                .profiles.map { try $0.migrated() }
        case ProfileDocument.currentSchemaVersion:
            loadedProfiles = try decoder.decode(ProfileDocument.self, from: data).profiles
        default:
            throw ProfileStoreError.unsupportedSchemaVersion(header.schemaVersion)
        }
        var profileIDs = Set<UUID>()
        for profile in loadedProfiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileStoreError.duplicateTunnelProfileID(profile.id)
            }
            try ProfileValidator.validate(profile, against: loadedProfiles)
        }
        self.profiles = loadedProfiles
    }

    public func save(_ profile: TunnelProfile, credential: String? = nil) throws {
        try ProfileValidator.validate(profile, against: profiles)
        let suppliedCredential = credential
        let previousCredential = try credentialStore.credential(for: profile.id)
        if profile.authenticationMethod == .password,
           suppliedCredential?.isEmpty != false,
           previousCredential == nil {
            throw ProfileValidationError.passwordRequired
        }
        var updatedProfiles = profiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
            for savedForward in updatedProfiles[index].localForwards {
                guard let updatedForward = profile.localForwards.first(where: { $0.id == savedForward.id }),
                      updatedForward.name == savedForward.name else {
                    throw ProfileStoreError.immutableLocalForwardChanged
                }
            }
            updatedProfiles[index] = profile
        } else {
            updatedProfiles.append(profile)
        }
        let data = try encoder.encode(ProfileDocument(profiles: updatedProfiles))
        let desiredCredential = profile.authenticationMethod == .systemDefault
            ? nil
            : suppliedCredential?.isEmpty == false ? suppliedCredential : previousCredential
        try setCredential(desiredCredential, for: profile.id)
        do {
            try persistence.save(data)
        } catch {
            try? setCredential(previousCredential, for: profile.id)
            throw error
        }
        profiles = updatedProfiles
    }

    private func setCredential(_ credential: String?, for profileID: UUID) throws {
        if let credential {
            try credentialStore.setCredential(credential, for: profileID)
        } else {
            try credentialStore.removeCredential(for: profileID)
        }
    }

}

private struct ProfileDocument: Codable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let profiles: [TunnelProfile]

    init(profiles: [TunnelProfile]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profiles = profiles
    }
}

private struct ProfileDocumentHeader: Decodable {
    let schemaVersion: Int
}

private struct LegacyProfileDocument: Decodable {
    let profiles: [LegacyTunnelProfile]
}

private struct LegacyTunnelProfile: Decodable {
    let id: UUID
    let displayName: TunnelProfileName
    let sshHostAlias: LegacySSHHostAlias
    let localForward: LegacyLocalForward

    func migrated() throws -> TunnelProfile {
        try TunnelProfile(
            id: id,
            displayName: displayName.rawValue,
            sshHostname: sshHostAlias.rawValue,
            listenAddress: localForward.listenAddress.rawValue,
            destinationHost: localForward.destinationHost.rawValue,
            localForwards: [
                LocalForward(
                    id: localForward.id,
                    name: localForward.name.rawValue,
                    listenPort: localForward.listenPort.rawValue,
                    destinationPort: localForward.destinationPort.rawValue
                ),
            ]
        )
    }
}

private struct LegacyVersionTwoProfileDocument: Decodable {
    let profiles: [LegacyVersionTwoTunnelProfile]
}

private struct LegacyVersionTwoTunnelProfile: Decodable {
    let id: UUID
    let displayName: TunnelProfileName
    let sshHostAlias: LegacySSHHostAlias
    let listenAddress: LoopbackAddress
    let destinationHost: DestinationHost
    let localForwards: [LocalForward]

    func migrated() throws -> TunnelProfile {
        try TunnelProfile(
            id: id,
            displayName: displayName.rawValue,
            sshHostname: sshHostAlias.rawValue,
            listenAddress: listenAddress.rawValue,
            destinationHost: destinationHost.rawValue,
            localForwards: localForwards
        )
    }
}

private struct LegacyLocalForward: Decodable {
    let id: UUID
    let name: LocalForwardName
    let listenAddress: LoopbackAddress
    let listenPort: PortNumber
    let destinationHost: DestinationHost
    let destinationPort: PortNumber
}
