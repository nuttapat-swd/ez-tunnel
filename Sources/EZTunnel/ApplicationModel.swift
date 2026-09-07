import Foundation
import SwiftUI
import EZTunnelCore

@MainActor
final class ApplicationModel: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile]
    @Published private(set) var lifecycleStates = [UUID: TunnelLifecycleState]()
    @Published private(set) var testConnectionOutcomes = [UUID: TestConnectionOutcome]()
    @Published var errorMessage: String?

    private let application: EZTunnelApplication

    init(application: EZTunnelApplication) {
        self.application = application
        self.profiles = application.profiles
        application.stateDidChange = { [weak self] profileID, state in
            self?.lifecycleStates[profileID] = state
        }
        application.testConnectionDidChange = { [weak self] profileID, outcome in
            self?.testConnectionOutcomes[profileID] = outcome
        }
    }

    static func makeDefault() -> ApplicationModel {
        do {
            return ApplicationModel(
                application: try EZTunnelApplication(
                    persistence: FileProfilePersistence.applicationSupport(),
                    credentialStore: KeychainSSHCredentialStore()
                )
            )
        } catch {
            let fallback = try! EZTunnelApplication(persistence: UnavailablePersistence())
            let model = ApplicationModel(application: fallback)
            model.errorMessage = error.localizedDescription
            return model
        }
    }

    func save(_ profile: TunnelProfile, credential: String?) -> Bool {
        do {
            try application.save(profile, credential: credential)
            profiles = application.profiles
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func state(of profileID: UUID) -> TunnelLifecycleState {
        lifecycleStates[profileID] ?? application.state(of: profileID)
    }

    func testConnection(_ profile: TunnelProfile, credential: String?) {
        do {
            try application.testConnection(profile, credential: credential)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testConnectionOutcome(for profileID: UUID) -> TestConnectionOutcome? {
        testConnectionOutcomes[profileID] ?? application.testConnectionOutcome(for: profileID)
    }

    func start(profileID: UUID) {
        do {
            try application.start(profileID: profileID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(profileID: UUID) {
        application.stop(profileID: profileID)
    }

    func toggle(profileID: UUID) {
        if state(of: profileID) == .stopped {
            start(profileID: profileID)
        } else if state(of: profileID) != .stopping {
            stop(profileID: profileID)
        }
    }

    func actionTitle(profileID: UUID) -> String {
        switch state(of: profileID) {
        case .stopped: "Start"
        case .connecting, .connected, .reconnecting, .needsAttention: "Stop"
        case .stopping: "Stopping"
        }
    }

    func canToggle(profileID: UUID) -> Bool {
        state(of: profileID) != .stopping
    }

    func quit() {
        application.quit()
    }

    func managementWindowDidClose() {
        application.managementWindowDidClose()
    }
}

private struct UnavailablePersistence: ProfilePersistence {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw CocoaError(.fileWriteUnknown) }
}
