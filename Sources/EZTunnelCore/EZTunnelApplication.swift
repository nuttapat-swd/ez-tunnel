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
        let document = try decoder.decode(ProfileDocument.self, from: data)
        guard document.schemaVersion == ProfileDocument.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        var profileIDs = Set<UUID>()
        for profile in document.profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileStoreError.duplicateTunnelProfileID(profile.id)
            }
            try ProfileValidator.validate(profile, against: document.profiles)
        }
        self.profiles = document.profiles
    }

    public func save(_ profile: TunnelProfile) throws {
        try ProfileValidator.validate(profile, against: profiles)
        var updatedProfiles = profiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
            let savedForward = updatedProfiles[index].localForward
            guard savedForward.id == profile.localForward.id,
                  savedForward.name == profile.localForward.name else {
                throw ProfileStoreError.immutableLocalForwardChanged
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
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profiles: [TunnelProfile]

    init(profiles: [TunnelProfile]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profiles = profiles
    }
}
