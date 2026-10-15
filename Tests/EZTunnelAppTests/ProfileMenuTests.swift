import Foundation
import Testing
import EZTunnelCore
@testable import EZTunnel

@MainActor
struct ProfileMenuTests {
    @Test
    func lifecycleUpdatesPreserveMultipleProfilesAndTheirOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = try EZTunnelApplication(persistence: FileProfilePersistence(
            fileURL: directory.appendingPathComponent("profiles.json")))
        for name in ["Zulu", "Alpha"] {
            try application.save(TunnelProfile(
                displayName: name, sshHostname: "ssh.example.com",
                portForwards: [.dynamicForward(DynamicForward(name: "SOCKS", listenPort: 1091))]))
        }
        let model = ApplicationModel(application: application)
        let original = model.profiles
        for state in [TunnelLifecycleState.connecting, .connected, .reconnecting,
                      .needsAttention("credential required"), .stopping, .stopped] {
            application.stateDidChange?(original[0].id, state)
            #expect(model.profiles == original)
            #expect(model.profiles.map { model.menuTitle(for: $0) }.count == 2)
            #expect(model.menuTitle(for: original[1]) == "\(original[1].displayName.rawValue) — Stopped")
        }
    }

    @Test
    func profileMenuKeepsNameAndLifecycleAlongsideConfigurationChanged() throws {
        let application = try EZTunnelApplication(
            persistence: UnavailablePersistence(startupError: NSError(domain: "test", code: 1)))
        let model = ApplicationModel(application: application)
        let profile = try TunnelProfile(
            displayName: "Prod-Inspectra", sshHostname: "ssh.example.com",
            portForwards: [.dynamicForward(DynamicForward(name: "SOCKS", listenPort: 1091))])
        let states: [(TunnelLifecycleState, String)] = [
            (.stopped, "Stopped"), (.connecting, "Connecting…"), (.connected, "Connected"),
            (.reconnecting, "Reconnecting"), (.needsAttention("credential required"), "Needs Attention"),
            (.stopping, "Stopping…"),
        ]
        for (state, label) in states {
            application.stateDidChange?(profile.id, state)
            #expect(model.menuTitle(for: profile) == "Prod-Inspectra — \(label)")
            #expect(model.canToggle(profileID: profile.id) == (state != .stopping))
            application.configurationChangedDidChange?(profile.id, true)
            #expect(model.menuTitle(for: profile) == "Prod-Inspectra — \(label) — Configuration Changed")
            application.configurationChangedDidChange?(profile.id, false)
        }
    }
}
