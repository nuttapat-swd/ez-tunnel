import Foundation
import Testing

@testable import EZTunnelCore

@MainActor
struct ReconnectProcessOwnershipTests {
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
