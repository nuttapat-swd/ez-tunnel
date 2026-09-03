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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        persistence: any ProfilePersistence
    ) throws {
        self.persistence = persistence
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

    public func save(_ profile: TunnelProfile) throws {
        try ProfileValidator.validate(profile, against: profiles)
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
        try persistence.save(data)
        profiles = updatedProfiles
    }

}

private struct ProfileDocument: Codable {
    static let currentSchemaVersion = 2

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
    let sshHostAlias: SSHHostAlias
    let localForward: LegacyLocalForward

    func migrated() throws -> TunnelProfile {
        try TunnelProfile(
            id: id,
            displayName: displayName.rawValue,
            sshHostAlias: sshHostAlias.rawValue,
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

private struct LegacyLocalForward: Decodable {
    let id: UUID
    let name: LocalForwardName
    let listenAddress: LoopbackAddress
    let listenPort: PortNumber
    let destinationHost: DestinationHost
    let destinationPort: PortNumber
}
