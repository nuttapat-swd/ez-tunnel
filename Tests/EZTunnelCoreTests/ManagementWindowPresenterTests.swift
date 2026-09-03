import EZTunnelAppSupport
import Testing

@MainActor
struct ManagementWindowPresenterTests {
    @Test
    func openingManagementWindowActivatesAppBeforeOpeningAndBringingWindowForward() {
        let operatingSystem = RecordingManagementWindowOperatingSystem()
        let presenter = ManagementWindowPresenter(operatingSystem: operatingSystem)

        presenter.present {
            operatingSystem.events.append(.openedWindow)
        }

        #expect(operatingSystem.events == [
            .activatedApplication,
            .openedWindow,
            .broughtWindowForward,
        ])
    }
}

@MainActor
private final class RecordingManagementWindowOperatingSystem: ManagementWindowOperatingSystem {
    enum Event: Equatable {
        case activatedApplication
        case openedWindow
        case broughtWindowForward
    }

    var events = [Event]()

    func activateApplication() {
        events.append(.activatedApplication)
    }

    func bringManagementWindowToFront() {
        events.append(.broughtWindowForward)
    }
}
