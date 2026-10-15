import EZTunnelAppSupport
import EZTunnelCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ApplicationModel
    let windowPresenter: ManagementWindowPresenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.profiles) { profile in
            Button {
                model.toggle(profileID: profile.id)
            } label: {
                Label {
                    Text(model.menuTitle(for: profile))
                } icon: {
                    Image(nsImage: statusIndicator(for: profile))
                }
            }
            .disabled(!model.canToggle(profileID: profile.id))
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

    private func statusIndicator(for profile: TunnelProfile) -> NSImage {
        let color: NSColor = switch model.state(of: profile.id) {
        case .connected: .systemGreen
        case .stopped, .stopping: .systemGray
        case .connecting, .reconnecting, .needsAttention: .systemOrange
        }
        // Non-template artwork preserves status colors in the native menu.
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 8, height: 8)).fill()
            return true
        }
    }

    private func showManagementWindow() {
        windowPresenter.present {
            openWindow(id: "management")
        }
    }
}
