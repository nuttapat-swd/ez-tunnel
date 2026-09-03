import SwiftUI
import EZTunnelAppSupport

struct MenuContent: View {
    @ObservedObject var model: ApplicationModel
    let windowPresenter: ManagementWindowPresenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Management Window") {
            showManagementWindow()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit EZ Tunnel") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showManagementWindow() {
        windowPresenter.present {
            openWindow(id: "management")
        }
    }
}
