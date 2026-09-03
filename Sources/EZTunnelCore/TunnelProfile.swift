import Foundation

public struct TunnelProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: TunnelProfileName
    public var sshHostAlias: SSHHostAlias
    public var localForward: LocalForward

    public init(
        id: UUID = UUID(),
        displayName: String,
        sshHostAlias: String,
        localForward: LocalForward
    ) throws {
        self.id = id
        self.displayName = try TunnelProfileName(rawValue: displayName)
        self.sshHostAlias = try SSHHostAlias(rawValue: sshHostAlias)
        self.localForward = localForward
    }
}

public struct LocalForward: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: LocalForwardName
    public var listenAddress: LoopbackAddress
    public var listenPort: PortNumber
    public var destinationHost: DestinationHost
    public var destinationPort: PortNumber

    public init(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int,
        destinationHost: String,
        destinationPort: Int
    ) throws {
        self.id = id
        self.name = try LocalForwardName(rawValue: name)
        self.listenAddress = try LoopbackAddress(validating: listenAddress)
        self.listenPort = try PortNumber(listenPort, field: "Listen port")
        self.destinationHost = try DestinationHost(rawValue: destinationHost)
        self.destinationPort = try PortNumber(destinationPort, field: "Destination port")
    }
}
