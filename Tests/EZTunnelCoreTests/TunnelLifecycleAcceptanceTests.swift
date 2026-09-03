import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct TunnelLifecycleAcceptanceTests {
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
