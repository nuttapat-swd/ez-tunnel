import EZTunnelCore
import ServiceManagement

@MainActor
protocol MacOSLoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: MacOSLoginItemService {}

@MainActor
final class MacOSLoginItemManager: LoginItemManaging {
    private let service: any MacOSLoginItemService

    init(service: any MacOSLoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if service.status == .notRegistered {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
