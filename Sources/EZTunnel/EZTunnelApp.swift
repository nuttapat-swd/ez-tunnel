import SwiftUI
import EZTunnelAppSupport

@main
struct EZTunnelApp: App {
    @StateObject private var model = ApplicationModel.makeDefault()
    private let windowPresenter = ManagementWindowPresenter(
        operatingSystem: MacOSManagementWindowOperatingSystem()
    )

    var body: some Scene {
        MenuBarExtra("EZ Tunnel", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuContent(model: model, windowPresenter: windowPresenter)
        }
        .menuBarExtraStyle(.menu)

        Window("EZ Tunnel", id: "management") {
            ManagementView(model: model, windowPresenter: windowPresenter)
                .frame(minWidth: 680, minHeight: 440)
        }
    }
}
