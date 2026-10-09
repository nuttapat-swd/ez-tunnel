import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct CrashRecoveryAcceptanceTests {
    @Test
    func failedJournalWritesPreventLaunchAndAllowStopToBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryPersistence()
        let journal = try RecoveryJournal(persistence: store)
        let supervisor = RecoverySupervisor()
        let application = try EZTunnelApplication(
            persistence: FileProfilePersistence(fileURL: directory.appendingPathComponent("profiles.json")),
            processSupervisor: supervisor, recoveryJournal: journal)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        store.failWrites = true
        #expect(throws: CocoaError.self) { try application.start(profileID: profile.id) }
        #expect(supervisor.requests.isEmpty)
        #expect(application.state(of: profile.id) == .stopped)
        store.failWrites = false
        try application.start(profileID: profile.id)
        store.failWrites = true
        application.stop(profileID: profile.id)
        #expect(application.state(of: profile.id) != .stopped)
        #expect(application.recoveryError != nil)
        store.failWrites = false
        application.stop(profileID: profile.id)
        #expect(journal.activeProfileIDs.isEmpty)
        #expect(application.state(of: profile.id) == .stopped)
    }
    @Test(arguments: [SSHProcessEvent.failed(.temporary("Network lost")), .failed(.needsAttention("Host key changed"))])
    func activeIntentSurvivesFailuresButStopRemovesIt(event: SSHProcessEvent) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalStore = FileProfilePersistence(fileURL: directory.appendingPathComponent("recovery.json"))
        let supervisor = RecoverySupervisor()
        let application = try EZTunnelApplication(
            persistence: FileProfilePersistence(fileURL: directory.appendingPathComponent("profiles.json")),
            processSupervisor: supervisor, recoveryJournal: RecoveryJournal(persistence: journalStore))
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.start(profileID: profile.id)
        supervisor.handler?(event)
        #expect(try RecoveryJournal(persistence: journalStore).activeProfileIDs == [profile.id])
        application.stop(profileID: profile.id)
        #expect(try RecoveryJournal(persistence: journalStore).activeProfileIDs.isEmpty)
        application.quit()
    }

    @Test
    func unsafeCleanupPausesRecoveryAndPreservesEvidenceAcrossQuit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileProfilePersistence(fileURL: directory.appendingPathComponent("profiles.json"))
        let journalStore = FileProfilePersistence(fileURL: directory.appendingPathComponent("recovery.json"))
        let journal = try RecoveryJournal(persistence: journalStore)
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        let os = RecoveryOS()
        let record = RecoveryProcess(pid: 123, startSeconds: 50, startMicroseconds: 10,
                                     controlPath: "/tmp/ez-tunnel-\(getuid())-\(UUID().uuidString)")
        os.current = RecoveryProcessIdentity(startSeconds: 50, startMicroseconds: 10, executable: "/usr/bin/ssh",
                                            arguments: ["ssh", "-M", "-S", record.controlPath], userID: getuid())
        os.canClose = false
        let supervisor = SystemOpenSSHProcessSupervisor(recoveryJournal: journal, recoveryOperatingSystem: os)
        let application = try EZTunnelApplication(persistence: persistence, processSupervisor: supervisor, recoveryJournal: journal)
        try application.save(profile)
        try journal.setActive(profile.id)
        try journal.record(record, for: profile.id)
        application.launch(.userInitiated)
        #expect(application.state(of: profile.id) == .needsAttention(RecoveryError.previousProcessStillRunning.localizedDescription))
        application.quit()
        #expect(try RecoveryJournal(persistence: journalStore).processes[profile.id] == record)
        os.canClose = true
        application.stop(profileID: profile.id)
        #expect(application.state(of: profile.id) == .stopped)
        #expect(try RecoveryJournal(persistence: journalStore).activeProfileIDs.isEmpty)
    }

    @Test
    func obsoleteProfileEntriesAreCleanedWithoutReconnecting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RecoveryJournal(persistence: FileProfilePersistence(fileURL: directory.appendingPathComponent("recovery.json")))
        try journal.setActive(UUID())
        let supervisor = RecoverySupervisor()
        let application = try EZTunnelApplication(persistence: FileProfilePersistence(fileURL: directory.appendingPathComponent("profiles.json")), processSupervisor: supervisor, recoveryJournal: journal)
        application.launch(.userInitiated)
        #expect(supervisor.requests.isEmpty)
        #expect(journal.activeProfileIDs.isEmpty)
    }

    @Test
    func systemInspectionReadsTheIdentityOfOnlyTheFixtureChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let os = SystemRecoveryProcessOperatingSystem()
        let identity = try #require(os.identity(pid: child.processIdentifier))
        #expect(identity.executable == "/bin/sleep")
        #expect(identity.arguments.last == "30")
        #expect(identity.startSeconds > 0)
        #expect(identity.userID == getuid())
        #expect(os.identity(pid: -1) == nil)
    }
    @Test
    func crashBetweenSpawningAndRecordingPIDFindsOnlyTheOwnedAttempt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RecoveryJournal(persistence: FileProfilePersistence(fileURL: directory.appendingPathComponent("recovery.json")))
        let profileID = UUID()
        let pending = RecoveryProcess(pid: 0, startSeconds: 0, startMicroseconds: 0,
                                      controlPath: "/tmp/ez-tunnel-\(getuid())-\(UUID().uuidString)")
        try journal.record(pending, for: profileID)
        let os = RecoveryOS()
        os.discovered = RecoveryProcess(pid: 123, startSeconds: 50, startMicroseconds: 10, controlPath: pending.controlPath)
        os.current = RecoveryProcessIdentity(startSeconds: 50, startMicroseconds: 10, executable: "/usr/bin/ssh",
                                             arguments: ["ssh", "-M", "-S", pending.controlPath], userID: getuid())
        let supervisor = SystemOpenSSHProcessSupervisor(recoveryJournal: journal, recoveryOperatingSystem: os)
        #expect(supervisor.recoverStaleProcesses().isEmpty)
        #expect(os.closed == [os.discovered!])
        #expect(journal.processes.isEmpty)
    }
    @Test(arguments: ["missing", "uninspectable", "reused", "metadata", "executable", "user", "owned", "blocked"])
    func staleProcessesRequireOwnershipAndIdentityBeforeTermination(scenario: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RecoveryJournal(persistence: FileProfilePersistence(fileURL: directory.appendingPathComponent("recovery.json")))
        let profileID = UUID()
        let process = RecoveryProcess(pid: 123, startSeconds: 50, startMicroseconds: 10, controlPath: "/tmp/ez-tunnel-\(getuid())-\(UUID().uuidString)")
        try journal.setActive(profileID)
        try journal.record(process, for: profileID)
        let os = RecoveryOS()
        if scenario != "missing" && scenario != "uninspectable" {
            os.current = RecoveryProcessIdentity(
                startSeconds: scenario == "reused" ? 51 : 50, startMicroseconds: 10,
                executable: scenario == "executable" ? "/bin/sleep" : "/usr/bin/ssh",
                arguments: ["ssh", "-M", "-S", scenario == "metadata" ? "/tmp/unrelated" : process.controlPath],
                userID: scenario == "user" ? getuid() + 1 : getuid())
        }
        os.inspectionUnavailable = scenario == "uninspectable"
        os.canClose = scenario != "blocked"
        let supervisor = SystemOpenSSHProcessSupervisor(recoveryJournal: journal, recoveryOperatingSystem: os)
        let blocked = supervisor.recoverStaleProcesses()
        #expect(os.closed.count == (["owned", "blocked"].contains(scenario) ? 1 : 0))
        #expect(blocked.isEmpty == (!["blocked", "uninspectable"].contains(scenario)))
        #expect(journal.processes.isEmpty == (!["blocked", "uninspectable"].contains(scenario)))
        #expect(journal.activeProfileIDs == [profileID])
    }
    @Test
    func crashRecoversCurrentSavedDefinitionAndCleanQuitClearsIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileProfilePersistence(fileURL: directory.appendingPathComponent("profiles.json"))
        let journalStore = FileProfilePersistence(fileURL: directory.appendingPathComponent("recovery.json"))
        let journal = try RecoveryJournal(persistence: journalStore)
        let first = try EZTunnelApplication(persistence: persistence, processSupervisor: RecoverySupervisor(), recoveryJournal: journal)
        var profile = try TunnelProfile(sshHostname: "old.invalid", portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try first.save(profile)
        try first.start(profileID: profile.id)
        profile.sshHostname = try SSHHostname(rawValue: "current.invalid")
        try first.save(profile)
        let supervisor = RecoverySupervisor()
        let recovered = try EZTunnelApplication(persistence: persistence, processSupervisor: supervisor, recoveryJournal: RecoveryJournal(persistence: journalStore))
        recovered.launch(.userInitiated)
        #expect(supervisor.requests.count == 1)
        #expect(supervisor.requests.first?.arguments.last == "current.invalid")
        #expect(supervisor.requests.first?.allowsInteraction == false)
        recovered.launch(.loginItem)
        #expect(supervisor.requests.count == 1)
        recovered.quit()
        #expect(try RecoveryJournal(persistence: journalStore).activeProfileIDs.isEmpty)
    }
}

private final class RecoveryPersistence: ProfilePersistence {
    var data: Data?
    var failWrites = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }
}

@MainActor
private final class RecoveryOS: RecoveryProcessOperatingSystem {
    var inspectionUnavailable = false
    var discovered: RecoveryProcess?
    func findProcess(controlPath: String) throws -> RecoveryProcess? { discovered }
    var current: RecoveryProcessIdentity?
    var canClose = true
    var closed = [RecoveryProcess]()
    func inspect(pid: Int32) -> RecoveryProcessInspection {
        if inspectionUnavailable { return .unavailable }
        return current.map { .present($0) } ?? .absent
    }
    func closeTunnel(_ process: RecoveryProcess) -> Bool {
        closed.append(process)
        if canClose { current = nil }
        return canClose
    }
}

@MainActor
private final class RecoverySupervisor: SSHProcessSupervising {
    var requests = [SSHProcessRequest]()
    var handler: (@MainActor @Sendable (SSHProcessEvent) -> Void)?
    func start(_ request: SSHProcessRequest, eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void) throws {
        requests.append(request)
        handler = eventHandler
    }
    func stop(profileID: UUID) {}
}
