import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct AutoStartAcceptanceTests {
    @Test
    func autoStartPersistsAndControlsLoginItemRegistration() throws {
        let persistence = AutoStartPersistence()
        let loginItem = RecordingLoginItemManager()
        let application = try EZTunnelApplication(
            persistence: persistence,
            loginItemManager: loginItem
        )
        var profile = try makeProfile(autoStart: true)

        try application.save(profile)
        #expect(loginItem.enabledValues == [false, true])

        let relaunched = try EZTunnelApplication(
            persistence: persistence,
            loginItemManager: RecordingLoginItemManager()
        )
        #expect(relaunched.profiles.first?.autoStart == true)

        profile.autoStart = false
        try application.save(profile)
        #expect(loginItem.enabledValues == [false, true, false])
    }

    @Test
    func loginLaunchStartsOnlyAutoStartProfilesWithoutInteraction() throws {
        let supervisor = AutoStartProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: AutoStartPersistence(),
            processSupervisor: supervisor
        )
        let selected = try makeProfile(autoStart: true)
        let unselected = try TunnelProfile(
            displayName: "Staging",
            sshHostname: "staging.example.com",
            localForwards: [
                LocalForward(name: "Web", listenPort: 8081, destinationPort: 80)
            ]
        )
        try application.save(selected)
        try application.save(unselected)

        application.launch(.userInitiated)
        #expect(supervisor.requests.isEmpty)

        application.launch(.loginItem)

        let request = try #require(supervisor.requests.first)
        #expect(supervisor.requests.map(\.profileID) == [selected.id])
        #expect(request.allowsInteraction == false)
        #expect(request.credential == nil)
        #expect(request.arguments.contains("BatchMode=yes"))
        #expect(application.state(of: selected.id) == .connecting)
        #expect(application.state(of: unselected.id) == .stopped)
    }

    @Test
    func interactionRequiredAtLoginNeedsAttentionWithoutRetrying() throws {
        let supervisor = AutoStartProcessSupervisor()
        let scheduler = AutoStartRetryScheduler()
        let application = try EZTunnelApplication(
            persistence: AutoStartPersistence(),
            processSupervisor: supervisor,
            retryScheduler: scheduler
        )
        let profile = try makeProfile(autoStart: true)
        try application.save(profile)

        application.launch(.loginItem)
        supervisor.report(
            .failed(.needsAttention("The SSH host key is not trusted.")),
            for: profile.id
        )

        #expect(
            application.state(of: profile.id)
                == .needsAttention("The SSH host key is not trusted.")
        )
        #expect(scheduler.scheduledDelays.isEmpty)
    }

    @Test
    func passwordAutoStartNeedsAttentionWithoutLaunchingAProcess() throws {
        let supervisor = AutoStartProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: AutoStartPersistence(),
            credentialStore: AutoStartCredentialStore(),
            processSupervisor: supervisor
        )
        let profile = try TunnelProfile(
            displayName: "Password server",
            sshHostname: "password.example.com",
            authenticationMethod: .password,
            autoStart: true,
            localForwards: [
                LocalForward(name: "Web", listenPort: 8082, destinationPort: 80)
            ]
        )
        try application.save(profile, credential: "secret")

        application.launch(.loginItem)

        #expect(supervisor.requests.isEmpty)
        guard case .needsAttention = application.state(of: profile.id) else {
            Issue.record("Password Auto-start Profile should Need Attention")
            return
        }
    }

    @Test
    func manualStartDoesNotEnableAutoStartOrTheLoginItem() throws {
        let loginItem = RecordingLoginItemManager()
        let supervisor = AutoStartProcessSupervisor()
        let application = try EZTunnelApplication(
            persistence: AutoStartPersistence(),
            processSupervisor: supervisor,
            loginItemManager: loginItem
        )
        let profile = try makeProfile(autoStart: false)
        try application.save(profile)

        try application.start(profileID: profile.id)

        #expect(application.profiles.first?.autoStart == false)
        #expect(loginItem.enabledValues == [false])
        #expect(supervisor.requests.first?.allowsInteraction == true)
    }

    private func makeProfile(autoStart: Bool) throws -> TunnelProfile {
        try TunnelProfile(
            displayName: "Production",
            sshHostname: "ssh.example.com",
            autoStart: autoStart,
            localForwards: [
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80)
            ]
        )
    }
}

private final class AutoStartPersistence: ProfilePersistence {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

@MainActor
private final class RecordingLoginItemManager: LoginItemManaging {
    private(set) var enabledValues = [Bool]()

    func setEnabled(_ enabled: Bool) throws {
        enabledValues.append(enabled)
    }
}

@MainActor
private final class AutoStartProcessSupervisor: SSHProcessSupervising {
    private(set) var requests = [SSHProcessRequest]()
    private var handlers = [UUID: @MainActor @Sendable (SSHProcessEvent) -> Void]()

    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        requests.append(request)
        handlers[request.profileID] = eventHandler
    }

    func stop(profileID: UUID) {}

    func report(_ event: SSHProcessEvent, for profileID: UUID) {
        handlers[profileID]?(event)
    }
}

@MainActor
private final class AutoStartRetryScheduler: TunnelRetryScheduling {
    private(set) var scheduledDelays = [TimeInterval]()
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        scheduledDelays.append(delay)
        return UUID()
    }
    func cancel(_ id: UUID) {}
}

private final class AutoStartCredentialStore: SSHCredentialStore {
    private var credentials = [SSHCredentialKey: String]()
    func credential(for key: SSHCredentialKey) throws -> String? { credentials[key] }
    func setCredential(_ credential: String, for key: SSHCredentialKey) throws {
        credentials[key] = credential
    }
    func removeCredential(for key: SSHCredentialKey) throws { credentials[key] = nil }
}
