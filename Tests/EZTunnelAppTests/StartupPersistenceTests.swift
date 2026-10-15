import Foundation
import ServiceManagement
import Testing
import EZTunnelCore
@testable import EZTunnel

@MainActor
struct StartupPersistenceTests {
    @Test
    func missingLoginItemDoesNotPreventSavingAndReopeningFirstProfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileProfilePersistence(
            fileURL: directory.appendingPathComponent("profiles.json")
        )
        let service = RecordingLoginItemService(status: .notFound)
        let application = try EZTunnelApplication(
            persistence: persistence,
            loginItemManager: MacOSLoginItemManager(service: service)
        )
        let model = ApplicationModel(application: application)
        let profile = try TunnelProfile(
            sshHostname: "ssh.example.com",
            portForwards: [.dynamicForward(DynamicForward(name: "kubectl", listenPort: 1091))]
        )

        #expect(model.save(profile, credential: nil))

        let reopened = try EZTunnelApplication(
            persistence: persistence,
            loginItemManager: MacOSLoginItemManager(service: service)
        )
        #expect(reopened.profiles == [profile])
        #expect(service.unregisterCalls == 0)
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval])
    func disablingLoginItemOnlyUnregistersExistingServices(status: SMAppService.Status) throws {
        let service = RecordingLoginItemService(status: status)

        try MacOSLoginItemManager(service: service).setEnabled(false)

        #expect(service.unregisterCalls == (status == .enabled || status == .requiresApproval ? 1 : 0))
    }

    @Test(arguments: [SSHAuthenticationMethod.systemDefault, .password, .privateKey])
    func startupFailureRemainsActionableWhenSavingWithoutExposingErrorDetails(
        authenticationMethod: SSHAuthenticationMethod
    ) throws {
        let persistence = UnavailablePersistence(startupError: NSError(
            domain: NSCocoaErrorDomain,
            code: 260,
            userInfo: [NSLocalizedDescriptionKey: "sensitive SSH settings"]
        ))
        let model = ApplicationModel(
            application: try EZTunnelApplication(persistence: persistence),
            startupFailureMessage: persistence.errorDescription
        )
        let profile = try TunnelProfile(
            sshHostname: "ssh.example.com",
            authenticationMethod: authenticationMethod,
            privateKeyPath: authenticationMethod == .privateKey ? "/tmp/id_ed25519" : nil,
            portForwards: [.dynamicForward(DynamicForward(name: "kubectl", listenPort: 1091))]
        )

        #expect(!model.save(profile, credential: "synthetic-secret"))

        let message = try #require(model.errorMessage)
        #expect(message.contains("could not finish starting"))
        #expect(message.contains("NSCocoaErrorDomain, code 260"))
        #expect(message.contains("Quit and reopen"))
        #expect(!message.contains("sensitive SSH settings"))
        #expect(!message.contains("synthetic-secret"))
        #expect(model.profiles.isEmpty)
    }
}

@MainActor
private final class RecordingLoginItemService: MacOSLoginItemService {
    let status: SMAppService.Status
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) { self.status = status }
    func register() throws {}
    func unregister() throws {
        unregisterCalls += 1
        if status == .notFound {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 57)
        }
    }
}
