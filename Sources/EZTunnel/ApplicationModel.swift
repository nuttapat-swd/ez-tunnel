import EZTunnelCore
import Foundation
import SwiftUI

@MainActor
final class ApplicationModel: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile]
    @Published private(set) var lifecycleStates = [UUID: TunnelLifecycleState]()
    @Published private(set) var changedConfigurationIDs = Set<UUID>()
    @Published private(set) var testConnectionOutcomes = [UUID: TestConnectionOutcome]()
    @Published var errorMessage: String?

    private let application: EZTunnelApplication
    private let startupFailureMessage: String?
    private var recoveryEvents: MacOSRecoveryEvents?

    init(application: EZTunnelApplication, startupFailureMessage: String? = nil) {
        self.application = application
        self.startupFailureMessage = startupFailureMessage
        self.errorMessage = startupFailureMessage
        self.profiles = application.profiles
        self.changedConfigurationIDs = Set(
            application.profiles.compactMap {
                application.configurationChanged(for: $0.id) ? $0.id : nil
            })
        application.stateDidChange = { [weak self] profileID, state in
            self?.lifecycleStates[profileID] = state
        }
        application.testConnectionDidChange = { [weak self] profileID, outcome in
            self?.testConnectionOutcomes[profileID] = outcome
        }
        application.configurationChangedDidChange = { [weak self] profileID, changed in
            if changed {
                self?.changedConfigurationIDs.insert(profileID)
            } else {
                self?.changedConfigurationIDs.remove(profileID)
            }
        }
    }

    static func makeDefault() -> ApplicationModel {
        do {
            let persistence = try FileProfilePersistence.applicationSupport()
            let recoveryJournal = try RecoveryJournal(persistence: FileProfilePersistence(
                fileURL: persistence.fileURL.deletingLastPathComponent().appendingPathComponent("recovery.json")))
            let model = ApplicationModel(
                application: try EZTunnelApplication(
                    persistence: persistence,
                    credentialStore: KeychainSSHCredentialStore(),
                    loginItemManager: MacOSLoginItemManager(),
                    recoveryJournal: recoveryJournal,
                    notificationDelivery: MacOSTunnelNotifications()
                )
            )
            model.recoveryEvents = MacOSRecoveryEvents(application: model.application)
            return model
        } catch {
            let persistence = UnavailablePersistence(startupError: error)
            let fallback = try! EZTunnelApplication(persistence: persistence)
            return ApplicationModel(
                application: fallback, startupFailureMessage: persistence.errorDescription
            )
        }
    }

    func save(_ profile: TunnelProfile, credential: String?) -> Bool {
        if let startupFailureMessage {
            errorMessage = startupFailureMessage
            return false
        }
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
        errorMessage = application.recoveryError
    }

    func restart(profileID: UUID) {
        do {
            try application.restart(profileID: profileID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func canRestart(profileID: UUID) -> Bool {
        state(of: profileID) != .stopped && state(of: profileID) != .stopping
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

    func menuTitle(for profile: TunnelProfile) -> String {
        let state = state(of: profile.id)
        let label = state.displayName + (state == .connecting || state == .stopping ? "…" : "")
        return "\(profile.displayName.rawValue) — \(label)"
            + (changedConfigurationIDs.contains(profile.id) ? " — Configuration Changed" : "")
    }

    func quit() {
        recoveryEvents?.stop()
        application.quit()
    }

    func launch(_ launch: ApplicationLaunch) {
        application.launch(launch)
        errorMessage = application.recoveryError
    }

    func managementWindowDidClose() {
        application.managementWindowDidClose()
    }
}

struct UnavailablePersistence: ProfilePersistence, LocalizedError {
    private let errorDomain: String
    private let errorCode: Int

    init(startupError: any Error) {
        let error = startupError as NSError
        errorDomain = error.domain
        errorCode = error.code
    }

    var errorDescription: String? {
        "Cannot save Tunnel Profile because EZ Tunnel could not finish starting "
            + "(\(errorDomain), code \(errorCode)). Quit and reopen EZ Tunnel. "
            + "If this persists, report this error."
    }

    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw self }
}
