import Foundation

public struct TunnelProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: TunnelProfileName
    public var sshHostAlias: SSHHostAlias
    public var listenAddress: LoopbackAddress
    public var destinationHost: DestinationHost
    public var localForwards: [LocalForward]

    public init(
        id: UUID = UUID(),
        displayName: String,
        sshHostAlias: String,
        listenAddress: String = "127.0.0.1",
        destinationHost: String,
        localForwards: [LocalForward]
    ) throws {
        self.id = id
        self.displayName = try TunnelProfileName(rawValue: displayName)
        self.sshHostAlias = try SSHHostAlias(rawValue: sshHostAlias)
        self.listenAddress = try LoopbackAddress(validating: listenAddress)
        self.destinationHost = try DestinationHost(rawValue: destinationHost)
        self.localForwards = localForwards
        try ProfileValidator.validateLocalForwards(localForwards)
    }

    public init(
        id: UUID = UUID(),
        sshHostAlias: String,
        listenAddress: String = "127.0.0.1",
        destinationHost: String,
        localForwards: [LocalForward]
    ) throws {
        try self.init(
            id: id,
            displayName: sshHostAlias,
            sshHostAlias: sshHostAlias,
            listenAddress: listenAddress,
            destinationHost: destinationHost,
            localForwards: localForwards
        )
    }
}

public struct LocalForward: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: LocalForwardName
    public var listenPort: PortNumber
    public var destinationPort: PortNumber

    public init(
        id: UUID = UUID(),
        name: String,
        listenPort: Int,
        destinationPort: Int
    ) throws {
        self.id = id
        self.name = try LocalForwardName(rawValue: name)
        self.listenPort = try PortNumber(listenPort, field: "Listen port")
        self.destinationPort = try PortNumber(destinationPort, field: "Destination port")
    }
}
