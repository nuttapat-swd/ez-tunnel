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
    public var remoteForwards: [RemoteForward]
    public var dynamicForwards: [DynamicForward]

    public var portForwards: [PortForward] {
        localForwards.map {
            .localForward(
                $0,
                listenAddress: listenAddress,
                destinationHost: destinationHost
            )
        }
            + remoteForwards.map(PortForward.remoteForward)
            + dynamicForwards.map(PortForward.dynamicForward)
    }

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
        self.remoteForwards = []
        self.dynamicForwards = []
        guard !localForwards.isEmpty else {
            throw ProfileValidationError.requiresPortForward
        }
        try ProfileValidator.validate(self)
    }

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        sshHostname: String,
        sshPort: Int = 22,
        sshUsername: String? = nil,
        authenticationMethod: SSHAuthenticationMethod = .systemDefault,
        privateKeyPath: String? = nil,
        portForwards: [PortForward]
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

        let local = portForwards.compactMap(\.localConfiguration)
        if let first = local.first,
           local.dropFirst().contains(where: {
               $0.listenAddress != first.listenAddress
                   || $0.destinationHost != first.destinationHost
           }) {
            throw ProfileValidationError.localForwardsRequireSharedHosts
        }
        self.listenAddress = local.first?.listenAddress ?? .ipv4
        if let destinationHost = local.first?.destinationHost {
            self.destinationHost = destinationHost
        } else {
            self.destinationHost = try DestinationHost(rawValue: "127.0.0.1")
        }
        self.localForwards = local.map(\.forward)
        self.remoteForwards = portForwards.compactMap(\.remoteConfiguration)
        self.dynamicForwards = portForwards.compactMap(\.dynamicConfiguration)
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

public struct RemoteForward: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: PortForwardName
    public var listenAddress: LoopbackAddress
    public var listenPort: PortNumber
    public var destinationHost: DestinationHost
    public var destinationPort: PortNumber

    public init(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int,
        destinationHost: String = "127.0.0.1",
        destinationPort: Int
    ) throws {
        self.id = id
        self.name = try PortForwardName(rawValue: name)
        self.listenAddress = try LoopbackAddress(validating: listenAddress)
        self.listenPort = try PortNumber(listenPort, field: "Listen port")
        self.destinationHost = try DestinationHost(rawValue: destinationHost)
        self.destinationPort = try PortNumber(destinationPort, field: "Destination port")
    }
}

public struct DynamicForward: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: PortForwardName
    public var listenAddress: LoopbackAddress
    public var listenPort: PortNumber

    public init(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int
    ) throws {
        self.id = id
        self.name = try PortForwardName(rawValue: name)
        self.listenAddress = try LoopbackAddress(validating: listenAddress)
        self.listenPort = try PortNumber(listenPort, field: "Listen port")
    }
}

public enum PortForwardMode: String, Codable, CaseIterable, Sendable {
    case local
    case remote
    case dynamic

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "Dynamic"
        }
    }
}

public enum PortForward: Equatable, Identifiable, Sendable {
    case localForward(
        LocalForward,
        listenAddress: LoopbackAddress,
        destinationHost: DestinationHost
    )
    case remoteForward(RemoteForward)
    case dynamicForward(DynamicForward)

    public var id: UUID {
        switch self {
        case .localForward(let forward, _, _): forward.id
        case .remoteForward(let forward): forward.id
        case .dynamicForward(let forward): forward.id
        }
    }

    public var name: PortForwardName {
        switch self {
        case .localForward(let forward, _, _): forward.name
        case .remoteForward(let forward): forward.name
        case .dynamicForward(let forward): forward.name
        }
    }

    public var mode: PortForwardMode {
        switch self {
        case .localForward: .local
        case .remoteForward: .remote
        case .dynamicForward: .dynamic
        }
    }

    public var listenAddress: LoopbackAddress {
        switch self {
        case .localForward(_, let address, _): address
        case .remoteForward(let forward): forward.listenAddress
        case .dynamicForward(let forward): forward.listenAddress
        }
    }

    public var listenPort: PortNumber {
        switch self {
        case .localForward(let forward, _, _): forward.listenPort
        case .remoteForward(let forward): forward.listenPort
        case .dynamicForward(let forward): forward.listenPort
        }
    }

    public static func local(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int,
        destinationHost: String = "127.0.0.1",
        destinationPort: Int
    ) throws -> Self {
        .localForward(
            try LocalForward(
                id: id,
                name: name,
                listenPort: listenPort,
                destinationPort: destinationPort
            ),
            listenAddress: try LoopbackAddress(validating: listenAddress),
            destinationHost: try DestinationHost(rawValue: destinationHost)
        )
    }

    public static func remote(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int,
        destinationHost: String = "127.0.0.1",
        destinationPort: Int
    ) throws -> Self {
        .remoteForward(try RemoteForward(
            id: id,
            name: name,
            listenAddress: listenAddress,
            listenPort: listenPort,
            destinationHost: destinationHost,
            destinationPort: destinationPort
        ))
    }

    public static func dynamic(
        id: UUID = UUID(),
        name: String,
        listenAddress: String = "127.0.0.1",
        listenPort: Int
    ) throws -> Self {
        .dynamicForward(try DynamicForward(
            id: id,
            name: name,
            listenAddress: listenAddress,
            listenPort: listenPort
        ))
    }

    fileprivate var localConfiguration: (
        forward: LocalForward,
        listenAddress: LoopbackAddress,
        destinationHost: DestinationHost
    )? {
        guard case .localForward(let forward, let address, let host) = self else { return nil }
        return (forward, address, host)
    }

    fileprivate var remoteConfiguration: RemoteForward? {
        guard case .remoteForward(let forward) = self else { return nil }
        return forward
    }

    fileprivate var dynamicConfiguration: DynamicForward? {
        guard case .dynamicForward(let forward) = self else { return nil }
        return forward
    }
}
