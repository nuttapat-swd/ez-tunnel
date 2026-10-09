import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct SleepRecoveryAcceptanceTests {
    @Test
    func sleepInterruptsTestConnectionAndIgnoresItsLateEvents() throws {
        let supervisor = SleepSupervisor()
        let application = try EZTunnelApplication(persistence: SleepPersistence(), processSupervisor: supervisor)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.testConnection(profile)
        let oldHandler = try #require(supervisor.handlers.last)
        application.systemWillSleep()
        application.systemDidWake()
        application.networkAvailabilityChanged(true)
        #expect(application.testConnectionOutcome(for: profile.id) != .testing)
        #expect(application.state(of: profile.id) == .stopped)
        try application.testConnection(profile)
        oldHandler(.ready)
        #expect(application.testConnectionOutcome(for: profile.id) == .testing)
        supervisor.handlers.last?(.ready)
        #expect(application.testConnectionOutcome(for: profile.id) == .succeeded)
        try application.start(profileID: profile.id)
    }

    @Test
    func sleepDoesNotResumeProfilesThatRequireIntervention() throws {
        let supervisor = SleepSupervisor()
        let application = try EZTunnelApplication(persistence: SleepPersistence(), processSupervisor: supervisor)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.start(profileID: profile.id)
        supervisor.handlers.last?(.failed(.needsAttention("Host key changed")))
        application.systemWillSleep()
        application.systemDidWake()
        application.networkAvailabilityChanged(true)
        #expect(application.state(of: profile.id) == .needsAttention("Host key changed"))
        #expect(supervisor.requests.count == 1)
    }

    @Test(arguments: ["owned", "unrelated", "reused", "uninspectable", "blocked"])
    func wakeVerifiesOwnershipThroughTheApplicationSeam(scenario: String) throws {
        let journal = try RecoveryJournal(persistence: SleepPersistence())
        let os = SleepRecoveryOS()
        let cleanup = SystemOpenSSHProcessSupervisor(recoveryJournal: journal, recoveryOperatingSystem: os)
        let supervisor = SleepSupervisor()
        supervisor.cleanup = { cleanup.recoverAfterWake() }
        let application = try EZTunnelApplication(persistence: SleepPersistence(), processSupervisor: supervisor,
            recoveryJournal: journal)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.start(profileID: profile.id)
        let record = RecoveryProcess(pid: 123, startSeconds: 50, startMicroseconds: 10,
            controlPath: "/tmp/ez-tunnel-\(getuid())-\(UUID().uuidString)")
        try journal.record(record, for: profile.id)
        os.current = RecoveryProcessIdentity(startSeconds: scenario == "reused" ? 51 : 50,
            startMicroseconds: 10, executable: "/usr/bin/ssh",
            arguments: ["ssh", "-M", "-S", scenario == "unrelated" ? "/tmp/unrelated" : record.controlPath],
            userID: getuid())
        os.unavailable = scenario == "uninspectable"
        os.canClose = scenario != "blocked"
        application.systemWillSleep()
        application.systemDidWake()
        application.networkAvailabilityChanged(true)
        #expect(os.closed.count == (["owned", "blocked"].contains(scenario) ? 1 : 0))
        let blocked = ["uninspectable", "blocked"].contains(scenario)
        #expect(supervisor.requests.count == (blocked ? 1 : 2))
        #expect(journal.processes.isEmpty == !blocked)
        #expect(journal.activeProfileIDs == [profile.id])
        if blocked {
            #expect(application.state(of: profile.id).displayName == "Needs Attention")
        } else {
            supervisor.handlers.last?(.ready)
            #expect(application.state(of: profile.id) == .connected)
        }
    }

    @Test
    func recoveryFailuresRetryOnlyWithNetworkAndStopCancelsRecovery() throws {
        let supervisor = SleepSupervisor()
        let scheduler = SleepScheduler()
        let application = try EZTunnelApplication(persistence: SleepPersistence(), processSupervisor: supervisor,
            retryScheduler: scheduler)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.start(profileID: profile.id)
        application.systemWillSleep()
        application.systemDidWake()
        application.networkAvailabilityChanged(true)
        supervisor.handlers.last?(.failed(.temporary("Timeout")))
        #expect(application.state(of: profile.id) == .reconnecting)
        #expect(scheduler.actions.count == 1)
        application.networkAvailabilityChanged(false)
        #expect(scheduler.actions.isEmpty)
        application.networkAvailabilityChanged(true)
        #expect(supervisor.requests.count == 3)
        supervisor.handlers.last?(.failed(.needsAttention("Host key changed")))
        #expect(application.state(of: profile.id) == .needsAttention("Host key changed"))
        #expect(scheduler.actions.isEmpty)
        application.systemWillSleep()
        application.stop(profileID: profile.id)
        application.systemDidWake()
        application.networkAvailabilityChanged(true)
        #expect(application.state(of: profile.id) == .stopped)
        #expect(supervisor.requests.count == 3)
    }

    @Test
    func blockedWakeCleanupNeedsAttentionWithoutStartingAnotherProcess() throws {
        let supervisor = SleepSupervisor()
        let application = try EZTunnelApplication(persistence: SleepPersistence(), processSupervisor: supervisor)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.start(profileID: profile.id)
        supervisor.blocked[profile.id] = "Cannot verify process"
        application.systemWillSleep()
        application.systemDidWake()
        application.networkAvailabilityChanged(true)
        application.systemDidWake()
        #expect(supervisor.cleanupCount == 1)
        #expect(supervisor.requests.count == 1)
        #expect(application.state(of: profile.id) == .needsAttention("Cannot verify process"))
    }

    @Test
    func sleepPreservesIntentAndWakeWaitsForNetworkUsingLatestProfile() throws {
        let journal = try RecoveryJournal(persistence: SleepPersistence())
        let supervisor = SleepSupervisor()
        let scheduler = SleepScheduler()
        let application = try EZTunnelApplication(persistence: SleepPersistence(), processSupervisor: supervisor,
            retryScheduler: scheduler, recoveryJournal: journal)
        var active = try TunnelProfile(sshHostname: "old.invalid", portForwards: [
            .localForward(try LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
                listenAddress: .ipv4, destinationHost: try DestinationHost(rawValue: "web.internal")),
            .remoteForward(try RemoteForward(name: "Webhook", listenPort: 9000, destinationPort: 9001)),
            .dynamic(name: "SOCKS", listenPort: 1080),
        ])
        let stopped = try TunnelProfile(sshHostname: "stopped.invalid", autoStart: true,
            portForwards: [.dynamic(name: "Other", listenPort: 1081)])
        try application.save(active)
        try application.save(stopped)
        try application.start(profileID: active.id)
        supervisor.handlers.last?(.ready)
        application.systemWillSleep()
        supervisor.handlers.last?(.failed(.temporary("late event")))
        #expect(application.state(of: active.id) == .reconnecting)
        #expect(journal.activeProfileIDs == [active.id])
        #expect(application.profiles == [active, stopped])
        #expect(scheduler.actions.isEmpty)
        active.sshHostname = try SSHHostname(rawValue: "current.invalid")
        try application.save(active)
        application.networkAvailabilityChanged(false)
        application.systemDidWake()
        #expect(supervisor.cleanupCount == 1)
        #expect(supervisor.requests.count == 1)
        application.networkAvailabilityChanged(true)
        #expect(supervisor.requests.count == 2)
        #expect(supervisor.requests.last?.arguments.last == "current.invalid")
        #expect(supervisor.requests.last?.allowsInteraction == false)
        #expect(supervisor.requests.last?.portForwards.count == 3)
        #expect(supervisor.requests.last?.arguments.contains("ExitOnForwardFailure=yes") == true)
        #expect(supervisor.requests.last?.arguments.contains("/dev/null") == true)
        #expect(application.state(of: stopped.id) == .stopped)
        supervisor.handlers.last?(.ready)
        #expect(application.state(of: active.id) == .connected)
        #expect(!application.configurationChanged(for: active.id))
    }
}

private final class SleepPersistence: ProfilePersistence {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

@MainActor
private final class SleepSupervisor: SSHProcessSupervising {
    var requests = [SSHProcessRequest]()
    var handlers = [@MainActor @Sendable (SSHProcessEvent) -> Void]()
    var cleanupCount = 0
    var blocked = [UUID: String]()
    var cleanup: (() -> [UUID: String])?
    func start(_ request: SSHProcessRequest, eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void) throws {
        requests.append(request)
        handlers.append(eventHandler)
    }
    func stop(profileID: UUID) {}
    func recoverAfterWake() -> [UUID: String] {
        cleanupCount += 1
        return cleanup?() ?? blocked
    }
}

@MainActor
private final class SleepRecoveryOS: RecoveryProcessOperatingSystem {
    var current: RecoveryProcessIdentity?
    var unavailable = false
    var canClose = true
    var closed = [RecoveryProcess]()
    func findProcess(controlPath: String) throws -> RecoveryProcess? { nil }
    func inspect(pid: Int32) -> RecoveryProcessInspection {
        if unavailable { return .unavailable }
        return current.map { .present($0) } ?? .absent
    }
    func closeTunnel(_ process: RecoveryProcess) -> Bool {
        closed.append(process)
        if canClose { current = nil }
        return canClose
    }
}

@MainActor
private final class SleepScheduler: TunnelRetryScheduling {
    var actions = [UUID: @MainActor @Sendable () -> Void]()
    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> UUID {
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
