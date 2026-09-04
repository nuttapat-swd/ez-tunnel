import Foundation

public enum SSHAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case systemDefault
    case privateKey
    case password

    public var displayName: String {
        switch self {
        case .systemDefault: "SSH Agent / System Default"
        case .privateKey: "Private Key File"
        case .password: "Password"
        }
    }
}

public struct TunnelProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: TunnelProfileName
    public var sshHostname: SSHHostname
    public var sshPort: PortNumber
    public var sshUsername: SSHUsername?
    public var authenticationMethod: SSHAuthenticationMethod
    public var privateKeyPath: String?
    public var listenAddress: LoopbackAddress
    public var destinationHost: DestinationHost
    public var localForwards: [LocalForward]

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        sshHostname: String,
        sshPort: Int = 22,
        sshUsername: String? = nil,
        authenticationMethod: SSHAuthenticationMethod = .systemDefault,
        privateKeyPath: String? = nil,
        listenAddress: String = "127.0.0.1",
        destinationHost: String = "127.0.0.1",
        localForwards: [LocalForward]
    ) throws {
        self.id = id
        self.displayName = try TunnelProfileName(rawValue: displayName ?? sshHostname)
        self.sshHostname = try SSHHostname(rawValue: sshHostname)
        self.sshPort = try PortNumber(sshPort, field: "SSH port")
        self.sshUsername = try sshUsername.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : try SSHUsername(rawValue: $0)
        }
        self.authenticationMethod = authenticationMethod
        let normalizedKeyPath = privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.privateKeyPath = normalizedKeyPath?.isEmpty == false ? normalizedKeyPath : nil
        self.listenAddress = try LoopbackAddress(validating: listenAddress)
        let normalizedDestinationHost = destinationHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.destinationHost = try DestinationHost(
            rawValue: normalizedDestinationHost.isEmpty ? "127.0.0.1" : destinationHost
        )
        self.localForwards = localForwards
        try ProfileValidator.validate(self)
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
