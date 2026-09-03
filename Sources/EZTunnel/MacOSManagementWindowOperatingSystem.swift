import AppKit
import EZTunnelAppSupport

@MainActor
final class MacOSManagementWindowOperatingSystem: ManagementWindowOperatingSystem {
    func activateApplication() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func bringManagementWindowToFront() {
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first(where: { $0.title == "EZ Tunnel" })?
                .makeKeyAndOrderFront(nil)
        }
    }
}
