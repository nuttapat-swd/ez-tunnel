import Foundation

public enum ProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateTunnelProfileID(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Profile schema version \(version) is not supported."
        case .duplicateTunnelProfileID(let id):
            "Tunnel Profile identity \(id.uuidString) appears more than once."
        }
    }
}

@MainActor
public final class EZTunnelApplication {
    public private(set) var profiles: [TunnelProfile]
    public var stateDidChange: (@MainActor (UUID, TunnelLifecycleState) -> Void)?

    private let persistence: any ProfilePersistence
    private let credentialStore: any SSHCredentialStore
    private let processSupervisor: any SSHProcessSupervising
    private let retryScheduler: any TunnelRetryScheduling
    private var lifecycleStates = [UUID: TunnelLifecycleState]()
    private var retryAttempts = [UUID: Int]()
    private var scheduledRetries = [UUID: UUID]()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        persistence: any ProfilePersistence,
        credentialStore: any SSHCredentialStore = UnavailableSSHCredentialStore(),
        processSupervisor: (any SSHProcessSupervising)? = nil,
        retryScheduler: (any TunnelRetryScheduling)? = nil
    ) throws {
        self.persistence = persistence
        self.credentialStore = credentialStore
        self.processSupervisor = processSupervisor ?? SystemOpenSSHProcessSupervisor()
        self.retryScheduler = retryScheduler ?? SystemTunnelRetryScheduler()
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
        let activeCredentialKey = profile.authenticationMethod.credentialKind.map {
            SSHCredentialKey(profileID: profile.id, kind: $0)
        }
        // Only touch the selected kind so changing authentication methods can
        // neither read nor overwrite a secret belonging to another kind.
        let credentialKeys = activeCredentialKey.map { [$0] } ?? SSHCredentialKind.allCases.map {
            SSHCredentialKey(profileID: profile.id, kind: $0)
        }
        let previousCredentials = try Dictionary(
            uniqueKeysWithValues: credentialKeys.map { key in
                (key, try credentialStore.credential(for: key))
            }
        )
        let previousActiveCredential = activeCredentialKey.flatMap { previousCredentials[$0] ?? nil }
        if profile.authenticationMethod == .password,
           suppliedCredential?.isEmpty != false,
           previousActiveCredential == nil {
            throw ProfileValidationError.passwordRequired
        }
        var updatedProfiles = profiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
            updatedProfiles[index] = profile
        } else {
            updatedProfiles.append(profile)
        }
        let data = try encoder.encode(ProfileDocument(profiles: updatedProfiles))
        do {
            if let activeCredentialKey {
                let desiredCredential = suppliedCredential?.isEmpty == false
                    ? suppliedCredential
                    : previousActiveCredential
                try setCredential(desiredCredential, for: activeCredentialKey)
            } else {
                for key in credentialKeys {
                    try setCredential(nil, for: key)
                }
            }
            try persistence.save(data)
        } catch {
            for key in credentialKeys {
                try? setCredential(previousCredentials[key] ?? nil, for: key)
            }
            throw error
        }
        profiles = updatedProfiles
    }

    public func state(of profileID: UUID) -> TunnelLifecycleState {
        lifecycleStates[profileID] ?? .stopped
    }

    public func start(profileID: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw TunnelLifecycleError.profileNotFound(profileID)
        }
        guard state(of: profileID) == .stopped else {
            throw TunnelLifecycleError.profileAlreadyActive(profileID)
        }
        transition(profileID, to: .connecting)
        do {
            try startProcess(for: profile, allowsInteraction: true)
        } catch {
            transition(profileID, to: .needsAttention(error.localizedDescription))
            throw error
        }
    }

    public func stop(profileID: UUID) {
        guard state(of: profileID) != .stopped else { return }
        transition(profileID, to: .stopping)
        cancelRetry(for: profileID)
        processSupervisor.stop(profileID: profileID)
        retryAttempts[profileID] = nil
        transition(profileID, to: .stopped)
    }

    public func quit() {
        for profileID in lifecycleStates.compactMap({ $0.value == .stopped ? nil : $0.key }) {
            stop(profileID: profileID)
        }
    }

    public func managementWindowDidClose() {
        // Active Profile intent belongs to the menu-bar application, not its window.
    }

    private func handle(_ event: SSHProcessEvent, for profileID: UUID) {
        guard state(of: profileID) != .stopped else { return }
        switch event {
        case .ready:
            retryAttempts[profileID] = nil
            transition(profileID, to: .connected)
        case .failed(.needsAttention(let message)):
            cancelRetry(for: profileID)
            transition(profileID, to: .needsAttention(message))
        case .failed(.temporary):
            transition(profileID, to: .reconnecting)
            scheduleRetry(for: profileID)
        }
    }

    private func startProcess(
        for profile: TunnelProfile,
        allowsInteraction: Bool
    ) throws {
        try processSupervisor.start(
            SSHProcessRequest(profile: profile, allowsInteraction: allowsInteraction)
        ) { [weak self] event in
            self?.handle(event, for: profile.id)
        }
    }

    private func scheduleRetry(for profileID: UUID) {
        cancelRetry(for: profileID)
        let backoff: [TimeInterval] = [1, 2, 5, 10, 30]
        let attempt = retryAttempts[profileID, default: 0]
        retryAttempts[profileID] = attempt + 1
        let delay = backoff[min(attempt, backoff.count - 1)]
        scheduledRetries[profileID] = retryScheduler.schedule(after: delay) { [weak self] in
            guard let self, self.state(of: profileID) == .reconnecting,
                  let profile = self.profiles.first(where: { $0.id == profileID }) else {
                return
            }
            self.scheduledRetries[profileID] = nil
            do {
                try self.startProcess(for: profile, allowsInteraction: false)
            } catch {
                self.transition(profileID, to: .needsAttention(error.localizedDescription))
            }
        }
    }

    private func cancelRetry(for profileID: UUID) {
        guard let retryID = scheduledRetries.removeValue(forKey: profileID) else { return }
        retryScheduler.cancel(retryID)
    }

    private func transition(_ profileID: UUID, to state: TunnelLifecycleState) {
        lifecycleStates[profileID] = state
        stateDidChange?(profileID, state)
    }

    private func setCredential(_ credential: String?, for key: SSHCredentialKey) throws {
        if let credential {
            try credentialStore.setCredential(credential, for: key)
        } else {
            try credentialStore.removeCredential(for: key)
        }
    }

}

private extension SSHAuthenticationMethod {
    var credentialKind: SSHCredentialKind? {
        switch self {
        case .systemDefault: nil
        case .privateKey: .privateKeyPassphrase
        case .password: .password
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
