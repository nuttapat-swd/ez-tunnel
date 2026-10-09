import EZTunnelCore
import Foundation
import UserNotifications

@MainActor
final class MacOSTunnelNotifications: NSObject, TunnelNotificationDelivering,
    UNUserNotificationCenterDelegate
{
    private let center = UNUserNotificationCenter.current()
    private var authorization: Task<Bool, Never>?

    override init() {
        super.init()
        center.delegate = self
    }

    func prepare(allowPermissionPrompt: Bool) {
        let center = center
        authorization = Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined && allowPermissionPrompt {
                return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }
            return settings.authorizationStatus == .authorized
        }
    }

    func deliver(_ notification: TunnelNotification) {
        let authorization = authorization
        let center = center
        Task {
            // Wait for any permission request, then honor current System Settings.
            _ = await authorization?.value
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.userInfo = ["profileID": notification.profileID.uuidString]
            try? await center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
