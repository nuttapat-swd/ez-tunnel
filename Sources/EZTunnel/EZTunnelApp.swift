import SwiftUI
import EZTunnelAppSupport
import AppKit

@main
struct EZTunnelApp: App {
    @StateObject private var model = AppDependencies.model
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

@MainActor
private enum AppDependencies {
    static let model = ApplicationModel.makeDefault()
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        AppDependencies.model.launch(isLoginItem ? .loginItem : .userInitiated)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDependencies.model.quit()
    }
}
