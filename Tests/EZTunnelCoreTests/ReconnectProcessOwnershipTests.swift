import Foundation
import Testing

@testable import EZTunnelCore

@MainActor
struct ReconnectProcessOwnershipTests {
    @Test
    func restartNowWaitsForOwnedProcessExitBeforeLaunchingTheSavedConfiguration() throws {
        var children = [Process]()
        var launchedArguments = [[String]]()
        let supervisor = SystemOpenSSHProcessSupervisor(
            askPassHelperURL: URL(fileURLWithPath: "/usr/bin/true")
        ) { process, request in
            #expect(children.allSatisfy { !$0.isRunning })
            launchedArguments.append(request.arguments)
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            children.append(process)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = try EZTunnelApplication(
            persistence: FileProfilePersistence(
                fileURL: directory.appendingPathComponent("profiles.json")),
            processSupervisor: supervisor)
        defer { application.quit() }
        var profile = try TunnelProfile(
            sshHostname: "original.invalid",
            portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        try application.save(profile)
        try application.start(profileID: profile.id)
        let originalChild = try #require(children.first)
        profile.sshHostname = try SSHHostname(rawValue: "replacement.invalid")
        try application.save(profile)
        #expect(originalChild.isRunning)

        try application.restart(profileID: profile.id)

        #expect(!originalChild.isRunning)
        #expect(children.count == 2)
        #expect(children.last?.isRunning == true)
        #expect(launchedArguments.last?.last == "replacement.invalid")
        application.stop(profileID: profile.id)
        #expect(children.allSatisfy { !$0.isRunning })
    }

    @Test
    func queuedTerminationFromAnOldAttemptCannotOrphanItsReplacement() async throws {
        var children = [Process]()
        let supervisor = SystemOpenSSHProcessSupervisor(
            askPassHelperURL: URL(fileURLWithPath: "/usr/bin/true")
        ) { process, _ in
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            children.append(process)
        }
        defer {
            for child in children where child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        let profile = try TunnelProfile(
            sshHostname: "fixture.invalid",
            portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)]
        )
        let request = SSHProcessRequest(profile: profile, allowsInteraction: false)
        var oldEvents = [SSHProcessEvent]()
        try supervisor.start(request) { oldEvents.append($0) }
        let oldChild = try #require(children.first)
        let queuedTermination = try #require(oldChild.terminationHandler)
        supervisor.stop(profileID: profile.id)
        // Deliver the OS callback after Stop, while its MainActor work is still queued.
        queuedTermination(oldChild)
        try supervisor.start(request) { _ in }
        let replacement = try #require(children.last)
        try await Task.sleep(for: .milliseconds(100))
        supervisor.stop(profileID: profile.id)
        #expect(oldEvents.isEmpty)
        #expect(!replacement.isRunning)
    }
}
