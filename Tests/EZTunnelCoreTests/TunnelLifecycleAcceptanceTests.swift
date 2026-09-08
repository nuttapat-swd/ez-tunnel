import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct TunnelLifecycleAcceptanceTests {
    @Test
    func manualStartUsesTheSelectedKeychainCredentialWithoutExposingItInArguments() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            credentialStore: LifecycleCredentialStore(),
            processSupervisor: supervisor
        )
        let profile = try TunnelProfile(
            sshHostname: "ssh.example.com",
            authenticationMethod: .password,
            localForwards: [LocalForward(name: "Web", listenPort: 8080, destinationPort: 80)]
        )
        try application.save(profile, credential: "synthetic-password")
        try application.start(profileID: profile.id)
        let request = try #require(supervisor.requests.first)
        #expect(request.credential == "synthetic-password")
        #expect(!request.arguments.joined().contains("synthetic-password"))
        supervisor.reportReady(profileID: profile.id)
        #expect(application.state(of: profile.id) == .connected)
    }

    @Test
    func testConnectionVerifiesTheDirectSSHEndpointWithoutOpeningPortForwards() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )

        try application.testConnection(profile)

        #expect(application.testConnectionOutcome(for: profile.id) == .testing)
        let request = try #require(supervisor.requests.first)
        #expect(request.executableURL.path == "/usr/bin/ssh")
        #expect(request.arguments.containsSubsequence(["-F", "/dev/null"]))
        #expect(request.arguments.containsSubsequence(["-o", "StrictHostKeyChecking=ask"]))
        #expect(request.arguments.containsSubsequence(["-p", "22"]))
        #expect(request.arguments.containsSubsequence(["-l", "deploy"]))
        #expect(request.arguments.suffix(2) == ["--", "production.example.com"])
        #expect(!request.arguments.contains("-L"))
        #expect(!request.arguments.contains("-R"))
        #expect(!request.arguments.contains("-D"))

        supervisor.reportReady(profileID: profile.id)

        #expect(application.testConnectionOutcome(for: profile.id) == .succeeded)
        #expect(supervisor.stoppedProfileIDs == [profile.id])
        #expect(application.profiles.isEmpty)
    }

    @Test
    func testConnectionDoesNotReplaceAnActiveProfilesOwnedProcess() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(profile)
        try application.start(profileID: profile.id)

        #expect(throws: TunnelLifecycleError.profileAlreadyActive(profile.id)) {
            try application.testConnection(profile)
        }

        #expect(supervisor.requests.count == 1)
        #expect(application.state(of: profile.id) == .connecting)
    }

    @Test
    func aSecondTestConnectionDoesNotReplaceTheTestAlreadyInProgress() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.testConnection(profile)

        #expect(throws: TunnelLifecycleError.testConnectionAlreadyInProgress(profile.id)) {
            try application.testConnection(profile)
        }

        #expect(supervisor.requests.count == 1)
        #expect(application.testConnectionOutcome(for: profile.id) == .testing)
    }

    @Test
    func startingAProfileDoesNotReplaceItsTestConnectionInProgress() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(profile)
        try application.testConnection(profile)

        #expect(throws: TunnelLifecycleError.testConnectionAlreadyInProgress(profile.id)) {
            try application.start(profileID: profile.id)
        }

        #expect(supervisor.requests.count == 1)
        #expect(application.testConnectionOutcome(for: profile.id) == .testing)
        #expect(application.state(of: profile.id) == .stopped)
    }

    @Test
    func passwordTestConnectionRequiresAStoredOrManuallySuppliedCredential() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let credentials = LifecycleCredentialStore()
        let profile = try TunnelProfile(
            displayName: "Password endpoint",
            sshHostname: "password.example.com",
            authenticationMethod: .password,
            localForwards: [
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            credentialStore: credentials,
            processSupervisor: supervisor
        )

        #expect(throws: ProfileValidationError.passwordRequired) {
            try application.testConnection(profile)
        }
        #expect(application.testConnectionOutcome(for: profile.id) == .needsAttention(
            "Enter the SSH password."
        ))
        #expect(supervisor.requests.isEmpty)

        try application.testConnection(profile, credential: "login-secret")
        let request = try #require(supervisor.requests.first)
        #expect(!request.arguments.contains(where: { $0.contains("login-secret") }))
        #expect(request.arguments.containsSubsequence(["-o", "NumberOfPasswordPrompts=1"]))
        supervisor.reportReady(profileID: profile.id)
        #expect(application.testConnectionOutcome(for: profile.id) == .succeeded)
    }

    @Test
    func testConnectionPresentsActionableAndTemporaryOpenSSHFailures() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )

        try application.testConnection(profile)
        let request = try #require(supervisor.requests.last)
        supervisor.reportFailure(
            profileID: profile.id,
            failure: SystemOpenSSHProcessSupervisor.interpretFailure(
                diagnostic: "Host key verification failed.\n",
                status: 255,
                portForwards: request.portForwards
            )
        )
        #expect(application.testConnectionOutcome(for: profile.id) == .needsAttention(
            "The SSH Endpoint host key is not trusted. Verify its fingerprint and add it to "
                + "known_hosts before retrying."
        ))
        #expect(application.testConnectionOutcome(for: profile.id)?.displayMessage ==
            "Test Connection Needs Attention: The SSH Endpoint host key is not trusted. "
                + "Verify its fingerprint and add it to known_hosts before retrying."
        )

        try application.testConnection(profile)
        let retryRequest = try #require(supervisor.requests.last)
        supervisor.reportFailure(
            profileID: profile.id,
            failure: SystemOpenSSHProcessSupervisor.interpretFailure(
                diagnostic: "ssh: connect to host production.example.com port 22: "
                    + "Connection timed out\n",
                status: 255,
                portForwards: retryRequest.portForwards
            )
        )
        #expect(application.testConnectionOutcome(for: profile.id) == .temporaryFailure(
            "ssh: connect to host production.example.com port 22: Connection timed out"
        ))
    }

    @Test
    func testConnectionExplainsChangedHostKeysAndUnavailablePrivateKeys() throws {
        let request = SSHProcessRequest(
            profile: try makeProfile(),
            allowsInteraction: true,
            includesPortForwards: false
        )

        let changedKey = SystemOpenSSHProcessSupervisor.interpretFailure(
            diagnostic: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\n",
            status: 255,
            portForwards: request.portForwards
        )
        #expect(changedKey == .needsAttention(
            "The SSH Endpoint host key has changed. Verify it outside EZ Tunnel; "
                + "automatic replacement is disabled."
        ))

        let unavailableKey = SystemOpenSSHProcessSupervisor.interpretFailure(
            diagnostic: "Warning: Identity file /missing/key not accessible: "
                + "No such file or directory.\n",
            status: 255,
            portForwards: request.portForwards
        )
        #expect(unavailableKey == .needsAttention(
            "The selected private key file is unavailable. Choose a readable private key."
        ))

        let normalIdentityBeforeTimeout = SystemOpenSSHProcessSupervisor.interpretFailure(
            diagnostic: "debug1: identity file /Users/example/.ssh/id_ed25519 type 3\n"
                + "ssh: connect to host production.example.com port 22: Connection timed out\n",
            status: 255,
            portForwards: request.portForwards
        )
        #expect(normalIdentityBeforeTimeout == .temporary(
            "ssh: connect to host production.example.com port 22: Connection timed out"
        ))
    }

    @Test
    func startingAProfileLaunchesOneOwnedOpenSSHProcessAndBecomesConnectedOnlyWhenReady() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(profile)

        try application.start(profileID: profile.id)

        #expect(application.state(of: profile.id) == .connecting)
        #expect(supervisor.requests.count == 1)
        #expect(supervisor.requests[0].executableURL.path == "/usr/bin/ssh")
        #expect(supervisor.requests[0].profileID == profile.id)

        supervisor.reportReady(profileID: profile.id)

        #expect(application.state(of: profile.id) == .connected)
    }

    @Test
    func openSSHArgumentsContainOnlyGeneratedEndpointAuthenticationForwardAndLifecycleOptions() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        let profile = try TunnelProfile(
            sshHostname: "ssh.example.com",
            sshPort: 2222,
            sshUsername: "deploy",
            authenticationMethod: .privateKey,
            privateKeyPath: "/keys/id_ed25519",
            listenAddress: "::1",
            destinationHost: "database.internal",
            localForwards: [
                LocalForward(name: "Database", listenPort: 15432, destinationPort: 5432),
                LocalForward(name: "Web", listenPort: 18080, destinationPort: 8080),
            ]
        )
        try application.save(profile)

        try application.start(profileID: profile.id)

        #expect(supervisor.requests[0].arguments == [
            "-v", "-N",
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-p", "2222",
            "-l", "deploy",
            "-o", "IdentitiesOnly=yes", "-i", "/keys/id_ed25519",
            "-L", "[::1]:15432:database.internal:5432",
            "-L", "[::1]:18080:database.internal:8080",
            "--", "ssh.example.com",
        ])
    }

    @Test
    func completeTunnelProfileStartsLocalRemoteAndDynamicForwardsInOneOpenSSHProcess() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        let profile = try TunnelProfile(
            displayName: "Complete profile",
            sshHostname: "ssh.example.com",
            portForwards: [
                PortForward.local(
                    name: "Database",
                    listenAddress: "127.0.0.1",
                    listenPort: 15432,
                    destinationHost: "database.internal",
                    destinationPort: 5432
                ),
                PortForward.remote(
                    name: "Webhook",
                    listenAddress: "::1",
                    listenPort: 19000,
                    destinationHost: "127.0.0.1",
                    destinationPort: 9000
                ),
                PortForward.dynamic(
                    name: "SOCKS",
                    listenAddress: "127.0.0.1",
                    listenPort: 1080
                ),
            ]
        )
        try application.save(profile)

        try application.start(profileID: profile.id)

        #expect(supervisor.requests.count == 1)
        #expect(supervisor.requests[0].arguments.containsSubsequence(
            ["-L", "127.0.0.1:15432:database.internal:5432"]
        ))
        #expect(supervisor.requests[0].arguments.containsSubsequence(
            ["-R", "[::1]:19000:127.0.0.1:9000"]
        ))
        #expect(supervisor.requests[0].arguments.containsSubsequence(
            ["-D", "127.0.0.1:1080"]
        ))

        supervisor.reportReady(profileID: profile.id)
        #expect(application.state(of: profile.id) == .connected)
    }

    @Test
    func connectedWaitsForTheSSHSessionAndEveryPortForwardReadinessConfirmation() throws {
        let supervisor = DiagnosticSSHProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        let profile = try TunnelProfile(
            displayName: "Complete profile",
            sshHostname: "ssh.example.com",
            portForwards: [
                PortForward.local(
                    name: "Database", listenPort: 15432,
                    destinationHost: "database.internal", destinationPort: 5432
                ),
                PortForward.remote(
                    name: "Webhook", listenPort: 19000,
                    destinationHost: "127.0.0.1", destinationPort: 9000
                ),
                PortForward.dynamic(name: "SOCKS", listenPort: 1080),
            ]
        )
        try application.save(profile)
        try application.start(profileID: profile.id)

        supervisor.receive("Entering interactive session", profileID: profile.id)
        supervisor.receive(
            "Local forwarding listening on 127.0.0.1 port 15432\n"
                + "Local forwarding listening on 127.0.0.1 port 1080",
            profileID: profile.id
        )

        #expect(application.state(of: profile.id) == .connecting)

        supervisor.receive(
            "remote forward success for: listen 127.0.0.1:19000, connect 127.0.0.1:9000",
            profileID: profile.id
        )

        #expect(application.state(of: profile.id) == .connected)
    }

    @Test
    func supervisedOpenSSHBehaviorRoutesAllThreePortForwardModes() throws {
        let supervisor = ForwardingBehaviorSSHProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        let profile = try TunnelProfile(
            displayName: "Complete profile",
            sshHostname: "ssh.example.com",
            portForwards: [
                PortForward.local(
                    name: "Database", listenPort: 15432,
                    destinationHost: "database.internal", destinationPort: 5432
                ),
                PortForward.remote(
                    name: "Webhook", listenAddress: "::1", listenPort: 19000,
                    destinationHost: "127.0.0.1", destinationPort: 9000
                ),
                PortForward.dynamic(name: "SOCKS", listenPort: 1080),
            ]
        )
        try application.save(profile)

        try application.start(profileID: profile.id)

        #expect(supervisor.localListener(
            address: "127.0.0.1", port: 15432,
            routesToHost: "database.internal", port: 5432
        ))
        #expect(supervisor.remoteListener(
            address: "::1", port: 19000,
            routesToHost: "127.0.0.1", port: 9000
        ))
        #expect(supervisor.dynamicListenerProvidesSOCKS(address: "127.0.0.1", port: 1080))
        #expect(supervisor.processCount == 1)
    }

    @Test
    func openSSHFailureNeedsAttentionWithoutReportingConnected() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(profile)
        try application.start(profileID: profile.id)

        supervisor.reportFailure(
            profileID: profile.id,
            failure: .needsAttention("Local Forward could not bind.")
        )

        #expect(application.state(of: profile.id) == .needsAttention(
            "Local Forward could not bind."
        ))
        #expect(supervisor.requests.count == 1)
    }

    @Test
    func temporaryOpenSSHFailureReconnectsAfterBackoff() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let retryScheduler = RecordingRetryScheduler()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor,
            retryScheduler: retryScheduler
        )
        try application.save(profile)
        try application.start(profileID: profile.id)

        supervisor.reportFailure(
            profileID: profile.id,
            failure: .temporary("Connection timed out.")
        )

        #expect(application.state(of: profile.id) == .reconnecting)
        #expect(retryScheduler.scheduledDelays == [1])

        retryScheduler.runNext()

        #expect(supervisor.requests.count == 2)
        #expect(application.state(of: profile.id) == .reconnecting)
        #expect(supervisor.requests[1].arguments.contains("BatchMode=yes"))
        #expect(supervisor.requests[1].arguments.contains("StrictHostKeyChecking=yes"))
        supervisor.reportReady(profileID: profile.id)
        #expect(application.state(of: profile.id) == .connected)
    }

    @Test
    func stoppingWhileReconnectingCancelsTheRetry() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let retryScheduler = RecordingRetryScheduler()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor,
            retryScheduler: retryScheduler
        )
        try application.save(profile)
        try application.start(profileID: profile.id)
        supervisor.reportFailure(
            profileID: profile.id,
            failure: .temporary("Connection refused.")
        )

        application.stop(profileID: profile.id)
        retryScheduler.runNext()

        #expect(application.state(of: profile.id) == .stopped)
        #expect(supervisor.requests.count == 1)
        #expect(retryScheduler.cancelledCount == 1)
    }

    @Test
    func stoppingAnActiveProfilePassesThroughStoppingAndLeavesNoOwnedProcess() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(profile)
        try application.start(profileID: profile.id)
        supervisor.reportReady(profileID: profile.id)
        supervisor.onStop = { stoppedProfileID in
            #expect(stoppedProfileID == profile.id)
            #expect(application.state(of: profile.id) == .stopping)
        }

        application.stop(profileID: profile.id)

        #expect(application.state(of: profile.id) == .stopped)
        #expect(supervisor.ownedProfileIDs.isEmpty)
    }

    @Test
    func quittingStopsEveryActiveProfileBeforeReturning() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let first = try makeProfile()
        let second = try TunnelProfile(
            displayName: "Admin",
            sshHostname: "admin.example.com",
            destinationHost: "admin.internal",
            localForwards: [
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(first)
        try application.save(second)
        try application.start(profileID: first.id)
        try application.start(profileID: second.id)

        application.quit()

        #expect(application.state(of: first.id) == .stopped)
        #expect(application.state(of: second.id) == .stopped)
        #expect(Set(supervisor.stoppedProfileIDs) == [first.id, second.id])
        #expect(supervisor.ownedProfileIDs.isEmpty)
    }

    @Test
    func closingTheManagementWindowLeavesTheActiveProfileRunning() throws {
        let supervisor = RecordingSSHProcessSupervisor()
        let profile = try makeProfile()
        let application = try EZTunnelApplication(
            persistence: LifecyclePersistence(),
            processSupervisor: supervisor
        )
        try application.save(profile)
        try application.start(profileID: profile.id)
        supervisor.reportReady(profileID: profile.id)

        application.managementWindowDidClose()

        #expect(application.state(of: profile.id) == .connected)
        #expect(supervisor.ownedProfileIDs == [profile.id])
    }

    private func makeProfile() throws -> TunnelProfile {
        try TunnelProfile(
            displayName: "Production database",
            sshHostname: "production.example.com",
            sshUsername: "deploy",
            destinationHost: "database.internal",
            localForwards: [
                LocalForward(name: "PostgreSQL", listenPort: 5432, destinationPort: 5432),
            ]
        )
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ candidate: [Element]) -> Bool {
        indices.contains { start in
            let end = index(start, offsetBy: candidate.count, limitedBy: endIndex) ?? endIndex
            return end - start == candidate.count && Array(self[start..<end]) == candidate
        }
    }
}

@MainActor
private final class RecordingSSHProcessSupervisor: SSHProcessSupervising {
    var requests = [SSHProcessRequest]()
    var stoppedProfileIDs = [UUID]()
    var onStop: ((UUID) -> Void)?
    var ownedProfileIDs: Set<UUID> { Set(eventHandlers.keys) }
    private var eventHandlers = [UUID: @MainActor @Sendable (SSHProcessEvent) -> Void]()

    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        requests.append(request)
        eventHandlers[request.profileID] = eventHandler
    }

    func stop(profileID: UUID) {
        stoppedProfileIDs.append(profileID)
        onStop?(profileID)
        eventHandlers[profileID] = nil
    }

    func reportReady(profileID: UUID) {
        eventHandlers[profileID]?(.ready)
    }

    func reportFailure(profileID: UUID, failure: SSHProcessFailure) {
        eventHandlers[profileID]?(.failed(failure))
        eventHandlers[profileID] = nil
    }
}

@MainActor
private final class DiagnosticSSHProcessSupervisor: SSHProcessSupervising {
    private var trackers = [UUID: SSHProcessReadinessTracker]()
    private var handlers = [UUID: @MainActor @Sendable (SSHProcessEvent) -> Void]()

    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        trackers[request.profileID] = SSHProcessReadinessTracker(
            portForwards: request.portForwards
        )
        handlers[request.profileID] = eventHandler
    }

    func stop(profileID: UUID) {
        trackers[profileID] = nil
        handlers[profileID] = nil
    }

    func receive(_ diagnostic: String, profileID: UUID) {
        guard var tracker = trackers[profileID] else { return }
        let isReady = tracker.receive(diagnostic)
        trackers[profileID] = tracker
        if isReady {
            handlers[profileID]?(.ready)
        }
    }
}

@MainActor
private final class ForwardingBehaviorSSHProcessSupervisor: SSHProcessSupervising {
    private var requests = [SSHProcessRequest]()
    var processCount: Int { requests.count }

    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        requests.append(request)
    }

    func stop(profileID: UUID) {}

    func localListener(
        address: String,
        port listenPort: Int,
        routesToHost destinationHost: String,
        port destinationPort: Int
    ) -> Bool {
        containsOption(
            "-L",
            value: "\(address):\(listenPort):\(destinationHost):\(destinationPort)"
        )
    }

    func remoteListener(
        address: String,
        port listenPort: Int,
        routesToHost destinationHost: String,
        port destinationPort: Int
    ) -> Bool {
        containsOption(
            "-R",
            value: "[\(address)]:\(listenPort):\(destinationHost):\(destinationPort)"
        )
    }

    func dynamicListenerProvidesSOCKS(address: String, port: Int) -> Bool {
        containsOption("-D", value: "\(address):\(port)")
    }

    private func containsOption(_ option: String, value: String) -> Bool {
        requests.contains { request in
            request.arguments.indices.contains { index in
                request.arguments[index] == option
                    && request.arguments.index(after: index) < request.arguments.endIndex
                    && request.arguments[request.arguments.index(after: index)] == value
            }
        }
    }
}

@MainActor
private final class RecordingRetryScheduler: TunnelRetryScheduling {
    var scheduledDelays = [TimeInterval]()
    var cancelledCount = 0
    private var actions = [UUID: @MainActor @Sendable () -> Void]()

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        scheduledDelays.append(delay)
        actions[id] = action
        return id
    }

    func cancel(_ id: UUID) {
        cancelledCount += 1
        actions[id] = nil
    }

    func runNext() {
        guard let id = actions.keys.first, let action = actions.removeValue(forKey: id) else {
            return
        }
        action()
    }
}

private final class LifecyclePersistence: ProfilePersistence {
    private var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

private final class LifecycleCredentialStore: SSHCredentialStore {
    private var credentials = [SSHCredentialKey: String]()

    func credential(for key: SSHCredentialKey) throws -> String? { credentials[key] }
    func setCredential(_ credential: String, for key: SSHCredentialKey) throws {
        credentials[key] = credential
    }
    func removeCredential(for key: SSHCredentialKey) throws { credentials[key] = nil }
}
