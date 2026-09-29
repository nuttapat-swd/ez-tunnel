import EZTunnelAppSupport
import EZTunnelCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ApplicationModel
    let windowPresenter: ManagementWindowPresenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.profiles) { profile in
            Button(menuTitle(for: profile)) {
                model.toggle(profileID: profile.id)
            }
            .disabled(!model.canToggle(profileID: profile.id))
            if model.canRestart(profileID: profile.id) {
                Button("Restart Now — \(profile.displayName.rawValue)") {
                    model.restart(profileID: profile.id)
                }
            }
        }
        if !model.profiles.isEmpty {
            Divider()
        }
        Button("Open Management Window") {
            showManagementWindow()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit EZ Tunnel") {
            model.quit()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func menuTitle(for profile: TunnelProfile) -> String {
        "\(model.actionTitle(profileID: profile.id)) \(profile.displayName.rawValue)"
            + " — \(model.state(of: profile.id).displayName)"
            + (model.changedConfigurationIDs.contains(profile.id) ? " — Configuration Changed" : "")
    }

    private func showManagementWindow() {
        windowPresenter.present {
            openWindow(id: "management")
        }
    }
}
