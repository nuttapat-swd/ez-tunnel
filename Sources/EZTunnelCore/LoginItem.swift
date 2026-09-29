import Foundation

@MainActor
public protocol LoginItemManaging: AnyObject {
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
public final class NoOpLoginItemManager: LoginItemManaging {
    public init() {}
    public func setEnabled(_ enabled: Bool) throws {}
}
