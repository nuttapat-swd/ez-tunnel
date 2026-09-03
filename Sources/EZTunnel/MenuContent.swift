import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ApplicationModel
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
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "management")
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.title == "EZ Tunnel" })?
                .makeKeyAndOrderFront(nil)
        }
    }
}
