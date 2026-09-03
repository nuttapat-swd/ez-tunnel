@MainActor
public protocol ManagementWindowOperatingSystem: AnyObject {
    func activateApplication()
    func bringManagementWindowToFront()
}

@MainActor
public struct ManagementWindowPresenter {
    private let operatingSystem: any ManagementWindowOperatingSystem

    public init(operatingSystem: any ManagementWindowOperatingSystem) {
        self.operatingSystem = operatingSystem
    }

    public func present(openWindow: () -> Void) {
        operatingSystem.activateApplication()
        openWindow()
        operatingSystem.bringManagementWindowToFront()
    }
}
