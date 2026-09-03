import Foundation

public struct TunnelProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var sshHostAlias: String
    public var localForward: LocalForward

    public init(
        id: UUID = UUID(),
        displayName: String,
        sshHostAlias: String,
        localForward: LocalForward
    ) {
        self.id = id
        self.displayName = displayName
        self.sshHostAlias = sshHostAlias
        self.localForward = localForward
    }
}

public struct LocalForward: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public var listenAddress: String
    public var listenPort: Int
    public var destinationHost: String
    public var destinationPort: Int

    public init(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int,
        destinationHost: String,
        destinationPort: Int
    ) {
        self.id = id
        self.name = name
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }
}
