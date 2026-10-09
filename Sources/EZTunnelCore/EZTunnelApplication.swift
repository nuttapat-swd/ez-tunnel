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

public enum TestConnectionOutcome: Equatable, Sendable {
    case testing
    case succeeded
    case needsAttention(String)
    case temporaryFailure(String)

    public var displayMessage: String {
        switch self {
        case .testing: "Testing SSH Endpoint…"
        case .succeeded: "Test Connection succeeded."
        case .needsAttention(let message): "Test Connection Needs Attention: \(message)"
        case .temporaryFailure(let message): "Test Connection could not connect: \(message)"
        }
    }
}

public enum ApplicationLaunch: Equatable, Sendable {
    case userInitiated
    case loginItem
}

@MainActor
public final class EZTunnelApplication {
    public private(set) var profiles: [TunnelProfile]
    public var stateDidChange: (@MainActor (UUID, TunnelLifecycleState) -> Void)?
    public var configurationChangedDidChange: (@MainActor (UUID, Bool) -> Void)?
    public var testConnectionDidChange: (@MainActor (UUID, TestConnectionOutcome) -> Void)?

    private let persistence: any ProfilePersistence
    private let credentialStore: any SSHCredentialStore
    private let processSupervisor: any SSHProcessSupervising
    private let retryScheduler: any TunnelRetryScheduling
    private let loginItemManager: any LoginItemManaging
    private let recoveryJournal: RecoveryJournal?
    private var recoveredLaunch = false
    public private(set) var recoveryError: String?
    private var lifecycleStates = [UUID: TunnelLifecycleState]()
    private var retryAttempts = [UUID: Int]()
    private var scheduledRetries = [UUID: UUID]()
    private var lifecycleAttemptIDs = [UUID: UUID]()
    private var attemptedProfiles = [UUID: TunnelProfile]()
    private var notifiedConfigurationChanges = Set<UUID>()
    private var testConnectionOutcomes = [UUID: TestConnectionOutcome]()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        persistence: any ProfilePersistence,
        credentialStore: any SSHCredentialStore = UnavailableSSHCredentialStore(),
        processSupervisor: (any SSHProcessSupervising)? = nil,
        retryScheduler: (any TunnelRetryScheduling)? = nil,
        loginItemManager: any LoginItemManaging = NoOpLoginItemManager(),
        recoveryJournal: RecoveryJournal? = nil
    ) throws {
        self.persistence = persistence
        self.credentialStore = credentialStore
        self.processSupervisor = processSupervisor ?? SystemOpenSSHProcessSupervisor(recoveryJournal: recoveryJournal)
        self.recoveryJournal = recoveryJournal
        self.retryScheduler = retryScheduler ?? SystemTunnelRetryScheduler()
        self.loginItemManager = loginItemManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try persistence.load() else {
            self.profiles = []
            try loginItemManager.setEnabled(false)
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
        case 3:
            loadedProfiles = try decoder.decode(LegacyVersionThreeProfileDocument.self, from: data)
                .profiles.map { try $0.migrated() }
        case 4, ProfileDocument.currentSchemaVersion:
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
        try loginItemManager.setEnabled(loadedProfiles.contains(where: \.autoStart))
    }

    public func save(_ profile: TunnelProfile, credential: String? = nil) throws {
        try ProfileValidator.validate(profile, against: profiles)
        let suppliedCredential = credential
        let activeCredentialKey = profile.authenticationMethod.credentialKind.map {
            SSHCredentialKey(profileID: profile.id, kind: $0)
        }
        // Only touch the selected kind so changing authentication methods can
        // neither read nor overwrite a secret belonging to another kind.
        let credentialKeys =
            activeCredentialKey.map { [$0] }
            ?? SSHCredentialKind.allCases.map {
                SSHCredentialKey(profileID: profile.id, kind: $0)
            }
        let previousCredentials = try Dictionary(
            uniqueKeysWithValues: credentialKeys.map { key in
                (key, try credentialStore.credential(for: key))
            }
        )
        let previousActiveCredential = activeCredentialKey.flatMap {
            previousCredentials[$0] ?? nil
        }
        if profile.authenticationMethod == .password,
            suppliedCredential?.isEmpty != false,
            previousActiveCredential == nil
        {
            throw ProfileValidationError.passwordRequired
        }
        var updatedProfiles = profiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) {
            updatedProfiles[index] = profile
        } else {
            updatedProfiles.append(profile)
        }
        let data = try encoder.encode(ProfileDocument(profiles: updatedProfiles))
        let wasLoginItemEnabled = profiles.contains(where: \.autoStart)
        let shouldEnableLoginItem = updatedProfiles.contains(where: \.autoStart)
        do {
            if shouldEnableLoginItem != wasLoginItemEnabled {
                try loginItemManager.setEnabled(shouldEnableLoginItem)
            }
            if let activeCredentialKey {
                let desiredCredential =
                    suppliedCredential?.isEmpty == false
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
            if shouldEnableLoginItem != wasLoginItemEnabled {
                try? loginItemManager.setEnabled(wasLoginItemEnabled)
            }
            for key in credentialKeys {
                try? setCredential(previousCredentials[key] ?? nil, for: key)
            }
            throw error
        }
        profiles = updatedProfiles
        notifyConfigurationChange(for: profile.id)
    }

    public func state(of profileID: UUID) -> TunnelLifecycleState {
        lifecycleStates[profileID] ?? .stopped
    }

    public func configurationChanged(for profileID: UUID) -> Bool {
        guard let attempted = attemptedProfiles[profileID],
            let saved = profiles.first(where: { $0.id == profileID })
        else { return false }
        return attempted != saved
    }

    public func testConnectionOutcome(for profileID: UUID) -> TestConnectionOutcome? {
        testConnectionOutcomes[profileID]
    }

    public func testConnection(_ profile: TunnelProfile, credential: String? = nil) throws {
        let profileID = profile.id
        guard state(of: profileID) == .stopped else {
            throw TunnelLifecycleError.profileAlreadyActive(profileID)
        }
        guard testConnectionOutcomes[profileID] != .testing else {
            throw TunnelLifecycleError.testConnectionAlreadyInProgress(profileID)
        }
        let storedCredential = try profile.authenticationMethod.credentialKind.flatMap {
            try credentialStore.credential(for: SSHCredentialKey(profileID: profileID, kind: $0))
        }
        let connectionCredential = credential?.isEmpty == false ? credential : storedCredential
        if profile.authenticationMethod == .password, connectionCredential == nil {
            let error = ProfileValidationError.passwordRequired
            let outcome = TestConnectionOutcome.needsAttention(error.localizedDescription)
            transitionTestConnection(profileID, to: outcome)
            throw error
        }
        let outcome = TestConnectionOutcome.testing
        transitionTestConnection(profileID, to: outcome)
        do {
            try processSupervisor.start(
                SSHProcessRequest(
                    profile: profile,
                    allowsInteraction: true,
                    includesPortForwards: false,
                    credential: connectionCredential
                )
            ) { [weak self] event in
                guard let self else { return }
                let outcome: TestConnectionOutcome
                switch event {
                case .ready:
                    self.processSupervisor.stop(profileID: profileID)
                    outcome = .succeeded
                case .failed(.needsAttention(let message)):
                    outcome = .needsAttention(message)
                case .failed(.temporary(let message)):
                    outcome = .temporaryFailure(message)
                }
                self.transitionTestConnection(profileID, to: outcome)
            }
        } catch {
            let outcome = TestConnectionOutcome.needsAttention(error.localizedDescription)
            transitionTestConnection(profileID, to: outcome)
            throw error
        }
    }

    public func start(profileID: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw TunnelLifecycleError.profileNotFound(profileID)
        }
        guard state(of: profileID) == .stopped else {
            throw TunnelLifecycleError.profileAlreadyActive(profileID)
        }
        guard testConnectionOutcomes[profileID] != .testing else {
            throw TunnelLifecycleError.testConnectionAlreadyInProgress(profileID)
        }
        try recoveryJournal?.setActive(profileID)
        transition(profileID, to: .connecting)
        do {
            try startProcess(for: profile, allowsInteraction: true)
        } catch {
            transition(profileID, to: .needsAttention(error.localizedDescription))
            throw error
        }
    }

    public func launch(_ launch: ApplicationLaunch) {
        var recoveredIDs = Set<UUID>()
        if !recoveredLaunch {
            recoveredLaunch = true
            recoveredIDs = recoveryJournal?.activeProfileIDs ?? []
            let blocked = processSupervisor.recoverStaleProcesses()
            for (id, message) in blocked where profiles.contains(where: { $0.id == id }) {
                transition(id, to: .needsAttention(message))
            }
            for id in recoveredIDs where !profiles.contains(where: { $0.id == id }) && blocked[id] == nil {
                do { try recoveryJournal?.stop(id) }
                catch { recoveryError = error.localizedDescription }
            }
        }
        for profile in profiles where (recoveredIDs.contains(profile.id) || (launch == .loginItem && profile.autoStart)) && state(of: profile.id) == .stopped {
            do { try recoveryJournal?.setActive(profile.id) }
            catch {
                recoveryError = error.localizedDescription
                transition(profile.id, to: .needsAttention(error.localizedDescription))
                continue
            }
            if let error = unattendedStartError(for: profile) {
                transition(profile.id, to: .needsAttention(error))
                continue
            }
            transition(profile.id, to: .connecting)
            do {
                try startProcess(for: profile, allowsInteraction: false)
            } catch {
                transition(profile.id, to: .needsAttention(error.localizedDescription))
            }
        }
    }

    public func stop(profileID: UUID) {
        guard state(of: profileID) != .stopped else { return }
        lifecycleAttemptIDs[profileID] = nil
        transition(profileID, to: .stopping)
        cancelRetry(for: profileID)
        processSupervisor.stop(profileID: profileID)
        guard recoveryJournal?.processes[profileID] == nil else {
            transition(profileID, to: .needsAttention(RecoveryError.previousProcessStillRunning.localizedDescription))
            return
        }
        do { try recoveryJournal?.stop(profileID) }
        catch {
            recoveryError = error.localizedDescription
            transition(profileID, to: .needsAttention(error.localizedDescription))
            return
        }
        recoveryError = nil
        retryAttempts[profileID] = nil
        attemptedProfiles[profileID] = nil
        notifyConfigurationChange(for: profileID)
        transition(profileID, to: .stopped)
    }

    public func restart(profileID: UUID) throws {
        stop(profileID: profileID)
        try start(profileID: profileID)
    }

    public func quit() {
        for profileID in lifecycleStates.compactMap({ $0.value == .stopped ? nil : $0.key }) {
            stop(profileID: profileID)
        }
        for profileID in testConnectionOutcomes.keys where testConnectionOutcomes[profileID] == .testing {
            processSupervisor.stop(profileID: profileID)
        }
        do {
            if recoveryJournal?.processes.isEmpty != false { try recoveryJournal?.clear() }
        }
        catch { recoveryError = error.localizedDescription }
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
            lifecycleAttemptIDs[profileID] = nil
            processSupervisor.stop(profileID: profileID)
            cancelRetry(for: profileID)
            transition(profileID, to: .needsAttention(message))
        case .failed(.temporary):
            lifecycleAttemptIDs[profileID] = nil
            processSupervisor.stop(profileID: profileID)
            transition(profileID, to: .reconnecting)
            scheduleRetry(for: profileID)
        }
    }

    private func startProcess(
        for profile: TunnelProfile,
        allowsInteraction: Bool
    ) throws {
        let attemptID = UUID()
        lifecycleAttemptIDs[profile.id] = attemptID
        attemptedProfiles[profile.id] = profile
        notifyConfigurationChange(for: profile.id)
        let credential =
            try allowsInteraction
            ? profile.authenticationMethod.credentialKind.flatMap {
                try credentialStore.credential(
                    for: SSHCredentialKey(profileID: profile.id, kind: $0))
            } : nil
        try processSupervisor.start(
            SSHProcessRequest(
                profile: profile, allowsInteraction: allowsInteraction, credential: credential
            )
        ) { [weak self] event in
            guard self?.lifecycleAttemptIDs[profile.id] == attemptID else { return }
            self?.handle(event, for: profile.id)
        }
    }

    private func scheduleRetry(for profileID: UUID) {
        cancelRetry(for: profileID)
        let backoff: [TimeInterval] = [1, 2, 5, 10, 30]
        let attempt = retryAttempts[profileID, default: 0]
        retryAttempts[profileID] = attempt + 1
        let delay = backoff[min(attempt, backoff.count - 1)]
        let retryAttemptID = UUID()
        lifecycleAttemptIDs[profileID] = retryAttemptID
        scheduledRetries[profileID] = retryScheduler.schedule(after: delay) { [weak self] in
            guard let self, self.state(of: profileID) == .reconnecting,
                self.lifecycleAttemptIDs[profileID] == retryAttemptID,
                let profile = self.profiles.first(where: { $0.id == profileID })
            else {
                return
            }
            self.lifecycleAttemptIDs[profileID] = nil
            self.scheduledRetries[profileID] = nil
            if let error = self.unattendedStartError(for: profile) {
                self.transition(profileID, to: .needsAttention(error))
                return
            }
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

    private func unattendedStartError(for profile: TunnelProfile) -> String? {
        guard profile.authenticationMethod == .password else { return nil }
        return "Password authentication requires a manual start. Stop this Tunnel Profile, then start it again."
    }

    private func notifyConfigurationChange(for profileID: UUID) {
        let changed = configurationChanged(for: profileID)
        guard changed != notifiedConfigurationChanges.contains(profileID) else { return }
        if changed {
            notifiedConfigurationChanges.insert(profileID)
        } else {
            notifiedConfigurationChanges.remove(profileID)
        }
        configurationChangedDidChange?(profileID, changed)
    }

    private func transition(_ profileID: UUID, to state: TunnelLifecycleState) {
        lifecycleStates[profileID] = state
        stateDidChange?(profileID, state)
    }

    private func transitionTestConnection(
        _ profileID: UUID,
        to outcome: TestConnectionOutcome
    ) {
        testConnectionOutcomes[profileID] = outcome
        testConnectionDidChange?(profileID, outcome)
    }

    private func setCredential(_ credential: String?, for key: SSHCredentialKey) throws {
        if let credential {
            try credentialStore.setCredential(credential, for: key)
        } else {
            try credentialStore.removeCredential(for: key)
        }
    }

}

private struct ProfileDocument: Codable {
    static let currentSchemaVersion = 5

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
                )
            ]
        )
    }
}

private struct LegacyVersionTwoProfileDocument: Decodable {
    let profiles: [LegacyVersionTwoTunnelProfile]
}

private struct LegacyVersionThreeProfileDocument: Decodable {
    let profiles: [LegacyVersionThreeTunnelProfile]
}

private struct LegacyVersionThreeTunnelProfile: Decodable {
    let id: UUID
    let displayName: TunnelProfileName
    let sshHostname: SSHHostname
    let sshPort: PortNumber
    let sshUsername: SSHUsername?
    let authenticationMethod: SSHAuthenticationMethod
    let privateKeyPath: String?
    let listenAddress: LoopbackAddress
    let destinationHost: DestinationHost
    let localForwards: [LocalForward]

    func migrated() throws -> TunnelProfile {
        try TunnelProfile(
            id: id,
            displayName: displayName.rawValue,
            sshHostname: sshHostname.rawValue,
            sshPort: sshPort.rawValue,
            sshUsername: sshUsername?.rawValue,
            authenticationMethod: authenticationMethod,
            privateKeyPath: privateKeyPath,
            listenAddress: listenAddress.rawValue,
            destinationHost: destinationHost.rawValue,
            localForwards: localForwards
        )
    }
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
