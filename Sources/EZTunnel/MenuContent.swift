import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ApplicationModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Management Window") {
            openWindow(id: "management")
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit EZ Tunnel") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
