import SwiftUI

@main
struct EZTunnelApp: App {
    @StateObject private var model = ApplicationModel.makeDefault()

    var body: some Scene {
        MenuBarExtra("EZ Tunnel", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("EZ Tunnel", id: "management") {
            ManagementView(model: model)
                .frame(minWidth: 680, minHeight: 440)
        }
    }
}
