import EZTunnelCore
import ServiceManagement

@MainActor
final class MacOSLoginItemManager: LoginItemManaging {
    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }
}
