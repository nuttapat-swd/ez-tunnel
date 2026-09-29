import Foundation
import Testing

@testable import EZTunnelAppSupport
@testable import EZTunnelCore

@MainActor
struct ConfigurationChangedAcceptanceTests {
    @Test
    func reconnectUsesEditsSavedDuringBackoffAndClearsTheBadge() throws {
        let harness = try ConfigurationHarness()
        let original = try harness.saveProfile()
        try harness.application.start(profileID: original.id)
        harness.supervisor.ready(original.id)
        harness.supervisor.fail(original.id)
        var draft = TunnelProfileDraft(profile: original)
        draft.sshHostname = "latest.example.com"
        draft.localForwards[0].listenPort = "8082"
        try harness.application.save(draft.makeProfile())
        #expect(harness.application.state(of: original.id) == .reconnecting)
        #expect(harness.application.configurationChanged(for: original.id))

        harness.scheduler.runNext()

        #expect(harness.supervisor.arguments(for: original.id).last == "latest.example.com")
        #expect(
            harness.supervisor.arguments(for: original.id).contains(
                "127.0.0.1:8082:web.internal:80"))
        #expect(harness.supervisor.arguments(for: original.id).contains("BatchMode=yes"))
        harness.supervisor.ready(original.id)
        #expect(harness.application.state(of: original.id) == .connected)
        #expect(!harness.application.configurationChanged(for: original.id))
    }

    @Test
    func editsAreIsolatedAndRevertingSavedValuesClearsTheBadge() throws {
        let harness = try ConfigurationHarness()
        let first = try harness.saveProfile()
        let second = try harness.saveProfile(name: "Other", port: 8081)
        let stopped = try harness.saveProfile(name: "Stopped", port: 8082)
        for profile in [first, second] {
            try harness.application.start(profileID: profile.id)
            harness.supervisor.ready(profile.id)
        }
        for original in [stopped, first] {
            var draft = TunnelProfileDraft(profile: original)
            draft.sshHostname = "edited.example.com"
            try harness.application.save(draft.makeProfile())
        }
        #expect(harness.application.configurationChanged(for: first.id))
        #expect(!harness.application.configurationChanged(for: second.id))
        #expect(!harness.application.configurationChanged(for: stopped.id))
        try harness.application.save(first)
        #expect(!harness.application.configurationChanged(for: first.id))
        #expect(harness.supervisor.stopped.isEmpty)
    }

    @Test
    func failedSaveChangesNeitherThePersistedProfileNorItsBadgeOrCredential() throws {
        let harness = try ConfigurationHarness()
        var original = try harness.saveProfile()
        original.authenticationMethod = .password
        try harness.application.save(original, credential: "original-synthetic-secret")
        try harness.application.start(profileID: original.id)
        harness.supervisor.ready(original.id)
        let originalData = harness.persistence.data
        var draft = TunnelProfileDraft(profile: original)
        draft.sshHostname = "unsaved.example.com"
        harness.persistence.failsSave = true

        #expect(throws: CocoaError.self) {
            try harness.application.save(
                draft.makeProfile(), credential: "unsaved-synthetic-secret")
        }

        #expect(harness.application.profiles == [original])
        #expect(harness.persistence.data == originalData)
        #expect(!harness.application.configurationChanged(for: original.id))
        #expect(harness.application.state(of: original.id) == .connected)
        #expect(harness.supervisor.stopped.isEmpty)
        let key = SSHCredentialKey(profileID: original.id, kind: .password)
        #expect(try harness.credentials.credential(for: key) == "original-synthetic-secret")
    }

    @Test(arguments: ["Connecting", "Reconnecting", "Needs Attention"])
    func editingAndRestartingAnActiveAttemptAppliesTheLatestSnapshot(stateName: String) throws {
        let harness = try ConfigurationHarness()
        let original = try harness.saveProfile()
        try harness.application.start(profileID: original.id)
        if stateName == "Reconnecting" { harness.supervisor.fail(original.id) }
        if stateName == "Needs Attention" {
            harness.supervisor.handlers[original.id]?(.failed(.needsAttention("Trust required")))
        }
        var draft = TunnelProfileDraft(profile: original)
        draft.sshHostname = "edited.example.com"
        try harness.application.save(draft.makeProfile())
        #expect(harness.application.state(of: original.id).displayName == stateName)
        #expect(harness.application.configurationChanged(for: original.id))
        let cancelledRetry = harness.scheduler.actions.values.first
        try harness.application.restart(profileID: original.id)
        cancelledRetry?()
        #expect(harness.scheduler.actions.isEmpty)
        #expect(harness.supervisor.requests.count == 1)
        #expect(harness.supervisor.arguments(for: original.id).last == "edited.example.com")
        #expect(!harness.application.configurationChanged(for: original.id))
        harness.supervisor.ready(original.id)
        #expect(harness.application.state(of: original.id) == .connected)
    }

    @Test
    func badgeUpdatesReachTheUIWithoutReplacingLifecycleState() throws {
        let harness = try ConfigurationHarness()
        let original = try harness.saveProfile()
        try harness.application.start(profileID: original.id)
        harness.supervisor.ready(original.id)
        var badgeUpdates = [Bool]()
        var lifecycleUpdates = [TunnelLifecycleState]()
        harness.application.configurationChangedDidChange = { id, changed in
            #expect(id == original.id)
            badgeUpdates.append(changed)
        }
        harness.application.stateDidChange = { _, state in lifecycleUpdates.append(state) }
        var edited = original
        edited.sshPort = try PortNumber(rawValue: 2222)
        try harness.application.save(edited)
        #expect(badgeUpdates == [true])
        #expect(lifecycleUpdates.isEmpty)
        try harness.application.save(original)
        #expect(badgeUpdates == [true, false])
        try harness.application.save(edited)
        harness.application.stop(profileID: original.id)
        #expect(badgeUpdates == [true, false, true, false])
    }

    @Test
    func restartNowReplacesAllForwardsWithTheLatestSavedValues() throws {
        let harness = try ConfigurationHarness()
        let original = try harness.saveProfile()
        try harness.application.start(profileID: original.id)
        harness.supervisor.ready(original.id)
        let oldHandler = try #require(harness.supervisor.handlers[original.id])
        var draft = TunnelProfileDraft(profile: original)
        draft.sshHostname = "replacement.example.com"
        draft.sshPort = "2222"
        draft.sshUsername = "deploy"
        draft.localForwards[0].destinationPort = "8081"
        draft.addRemoteForward()
        draft.remoteForwards[0].name = "Webhook"
        draft.remoteForwards[0].listenPort = "9000"
        draft.remoteForwards[0].destinationPort = "9001"
        draft.addDynamicForward()
        draft.dynamicForwards[0].name = "SOCKS"
        draft.dynamicForwards[0].listenPort = "1080"
        try harness.application.save(draft.makeProfile())

        try harness.application.restart(profileID: original.id)

        #expect(harness.supervisor.stopped == [original.id])
        #expect(harness.application.state(of: original.id) == .connecting)
        let arguments = harness.supervisor.arguments(for: original.id)
        #expect(arguments.last == "replacement.example.com")
        #expect(arguments.contains("2222"))
        #expect(arguments.contains("deploy"))
        #expect(arguments.contains("127.0.0.1:8080:web.internal:8081"))
        #expect(arguments.contains("127.0.0.1:9000:127.0.0.1:9001"))
        #expect(arguments.contains("127.0.0.1:1080"))
        oldHandler(.failed(.temporary("Late old process exit")))
        #expect(harness.application.state(of: original.id) == .connecting)
        harness.supervisor.ready(original.id)
        #expect(harness.application.state(of: original.id) == .connected)
        #expect(!harness.application.configurationChanged(for: original.id))
    }

    @Test
    func savingConnectedEditsKeepsTheOriginalForwardsAndPrimaryState() throws {
        let harness = try ConfigurationHarness()
        let original = try harness.saveProfile()
        try harness.application.start(profileID: original.id)
        harness.supervisor.ready(original.id)
        #expect(!harness.application.configurationChanged(for: original.id))

        var draft = TunnelProfileDraft(profile: original)
        draft.sshHostname = "replacement.example.com"
        draft.localForwards[0].destinationPort = "8081"
        let edited = try draft.makeProfile()
        try harness.application.save(edited)

        #expect(harness.application.state(of: original.id) == .connected)
        #expect(harness.application.configurationChanged(for: original.id))
        #expect(
            harness.supervisor.arguments(for: original.id).contains(
                "127.0.0.1:8080:web.internal:80"))
        #expect(harness.supervisor.arguments(for: original.id).last == "ssh.example.com")
        #expect(harness.supervisor.stopped.isEmpty)
        #expect(try EZTunnelApplication(persistence: harness.persistence).profiles == [edited])
    }
}

@MainActor
private struct ConfigurationHarness {
    let persistence = ConfigurationPersistence()
    let supervisor = ConfigurationSupervisor()
    let scheduler = ConfigurationScheduler()
    let credentials = ConfigurationCredentials()
    let application: EZTunnelApplication

    init() throws {
        application = try EZTunnelApplication(
            persistence: persistence, credentialStore: credentials,
            processSupervisor: supervisor, retryScheduler: scheduler)
    }

    func saveProfile(name: String = "Web", port: Int = 8080) throws -> TunnelProfile {
        let profile = try TunnelProfile(
            displayName: name, sshHostname: "ssh.example.com", destinationHost: "web.internal",
            localForwards: [LocalForward(name: "Web", listenPort: port, destinationPort: 80)])
        try application.save(profile)
        return profile
    }
}

private final class ConfigurationPersistence: ProfilePersistence {
    var data: Data?
    var failsSave = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }
}

private final class ConfigurationCredentials: SSHCredentialStore {
    var values = [SSHCredentialKey: String]()
    func credential(for key: SSHCredentialKey) throws -> String? { values[key] }
    func setCredential(_ credential: String, for key: SSHCredentialKey) throws {
        values[key] = credential
    }
    func removeCredential(for key: SSHCredentialKey) throws { values[key] = nil }
}

@MainActor
private final class ConfigurationSupervisor: SSHProcessSupervising {
    var requests = [UUID: SSHProcessRequest]()
    var handlers = [UUID: @MainActor @Sendable (SSHProcessEvent) -> Void]()
    var stopped = [UUID]()

    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        #expect(
            requests[request.profileID] == nil, "Restart must release the old owned process first")
        requests[request.profileID] = request
        handlers[request.profileID] = eventHandler
    }

    func stop(profileID: UUID) {
        stopped.append(profileID)
        requests[profileID] = nil
        handlers[profileID] = nil
    }

    func arguments(for id: UUID) -> [String] { requests[id]?.arguments ?? [] }
    func ready(_ id: UUID) { handlers[id]?(.ready) }
    func fail(_ id: UUID) { handlers[id]?(.failed(.temporary("Network lost"))) }
}

@MainActor
private final class ConfigurationScheduler: TunnelRetryScheduling {
    var actions = [UUID: @MainActor @Sendable () -> Void]()
    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void)
        -> UUID
    {
        let id = UUID()
        actions[id] = action
        return id
    }
    func cancel(_ id: UUID) { actions[id] = nil }
    func runNext() {
        guard let id = actions.keys.first else { return }
        actions.removeValue(forKey: id)?()
    }
}
