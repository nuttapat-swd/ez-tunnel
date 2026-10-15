import Foundation

public struct TunnelNotification: Equatable, Sendable {
    public let profileID: UUID
    public let title: String
    public let body: String
}

@MainActor
public protocol TunnelNotificationDelivering {
    func prepare(allowPermissionPrompt: Bool)
    func deliver(_ notification: TunnelNotification)
}

extension TunnelNotificationDelivering {
    public func prepare(allowPermissionPrompt: Bool) {}
}

public struct NoOpTunnelNotificationDelivery: TunnelNotificationDelivering {
    public init() {}
    public func deliver(_ notification: TunnelNotification) {}
}
