import Foundation
import EZTunnelCore

public struct TunnelProfileDraft {
    public let profileID: UUID
    public var displayName: String
    public var sshHostname: String
    public var sshPort: String
    public var sshUsername: String
    public var authenticationMethod: SSHAuthenticationMethod
    public var privateKeyPath: String
    public var credential: String
    public var listenAddress: String
    public var destinationHost: String
    public var localForwards: [LocalForwardDraft]
    public var remoteForwards: [RemoteForwardDraft]
    public var dynamicForwards: [DynamicForwardDraft]

    public init(profileID: UUID = UUID()) {
        self.profileID = profileID
        self.displayName = ""
        self.sshHostname = ""
        self.sshPort = "22"
        self.sshUsername = ""
        self.authenticationMethod = .systemDefault
        self.privateKeyPath = ""
        self.credential = ""
        self.listenAddress = "127.0.0.1"
        self.destinationHost = ""
        self.localForwards = [LocalForwardDraft()]
        self.remoteForwards = []
        self.dynamicForwards = []
    }

    public init(profile: TunnelProfile) {
        self.profileID = profile.id
        self.displayName = profile.displayName.rawValue
        self.sshHostname = profile.sshHostname.rawValue
        self.sshPort = String(profile.sshPort.rawValue)
        self.sshUsername = profile.sshUsername?.rawValue ?? ""
        self.authenticationMethod = profile.authenticationMethod
        self.privateKeyPath = profile.privateKeyPath ?? ""
        self.credential = ""
        self.listenAddress = profile.listenAddress.rawValue
        self.destinationHost = profile.destinationHost.rawValue
        self.localForwards = profile.localForwards.map(LocalForwardDraft.init)
        self.remoteForwards = profile.remoteForwards.map(RemoteForwardDraft.init)
        self.dynamicForwards = profile.dynamicForwards.map(DynamicForwardDraft.init)
    }

    public mutating func addLocalForward() {
        localForwards.append(LocalForwardDraft())
    }

    public mutating func removeLocalForward(id: UUID) {
        localForwards.removeAll { $0.id == id }
    }

    public mutating func addRemoteForward() {
        remoteForwards.append(RemoteForwardDraft())
    }

    public mutating func removeRemoteForward(id: UUID) {
        remoteForwards.removeAll { $0.id == id }
    }

    public mutating func addDynamicForward() {
        dynamicForwards.append(DynamicForwardDraft())
    }

    public mutating func removeDynamicForward(id: UUID) {
        dynamicForwards.removeAll { $0.id == id }
    }

    public func makeProfile() throws -> TunnelProfile {
        guard let sshPort = Int(sshPort) else {
            throw ProfileValidationError.invalidPort(field: "SSH port", value: 0)
        }
        let local = try localForwards.map {
            try PortForward.local(
                id: $0.id,
                name: $0.name,
                listenAddress: listenAddress,
                listenPort: $0.parsedListenPort(),
                destinationHost: destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? "127.0.0.1" : destinationHost,
                destinationPort: $0.parsedDestinationPort()
            )
        }
        let remote = try remoteForwards.map { try $0.makePortForward() }
        let dynamic = try dynamicForwards.map { try $0.makePortForward() }
        return try TunnelProfile(
            id: profileID,
            displayName: displayName,
            sshHostname: sshHostname,
            sshPort: sshPort,
            sshUsername: sshUsername,
            authenticationMethod: authenticationMethod,
            privateKeyPath: privateKeyPath,
            portForwards: local + remote + dynamic
        )
    }
}

public struct LocalForwardDraft: Identifiable {
    public let id: UUID
    public var name: String
    public var listenPort: String
    public var destinationPort: String

    public init(id: UUID = UUID()) {
        self.id = id
        self.name = ""
        self.listenPort = ""
        self.destinationPort = ""
    }

    public init(_ localForward: LocalForward) {
        self.id = localForward.id
        self.name = localForward.name.rawValue
        self.listenPort = String(localForward.listenPort.rawValue)
        self.destinationPort = String(localForward.destinationPort.rawValue)
    }

    public func makeLocalForward() throws -> LocalForward {
        guard let listenPort = Int(listenPort), let destinationPort = Int(destinationPort) else {
            throw ProfileValidationError.invalidPort(field: "Port", value: 0)
        }
        return try LocalForward(
            id: id,
            name: name,
            listenPort: listenPort,
            destinationPort: destinationPort
        )
    }


    fileprivate func parsedListenPort() throws -> Int {
        guard let listenPort = Int(listenPort) else {
            throw ProfileValidationError.invalidPort(field: "Listen port", value: 0)
        }
        return listenPort
    }

    fileprivate func parsedDestinationPort() throws -> Int {
        guard let destinationPort = Int(destinationPort) else {
            throw ProfileValidationError.invalidPort(field: "Destination port", value: 0)
        }
        return destinationPort
    }
}

public struct RemoteForwardDraft: Identifiable {
    public let id: UUID
    public var name: String
    public var listenAddress: String
    public var listenPort: String
    public var destinationHost: String
    public var destinationPort: String

    public init(id: UUID = UUID()) {
        self.id = id
        self.name = ""
        self.listenAddress = "127.0.0.1"
        self.listenPort = ""
        self.destinationHost = "127.0.0.1"
        self.destinationPort = ""
    }

    public init(_ remoteForward: RemoteForward) {
        self.id = remoteForward.id
        self.name = remoteForward.name.rawValue
        self.listenAddress = remoteForward.listenAddress.rawValue
        self.listenPort = String(remoteForward.listenPort.rawValue)
        self.destinationHost = remoteForward.destinationHost.rawValue
        self.destinationPort = String(remoteForward.destinationPort.rawValue)
    }

    public func makePortForward() throws -> PortForward {
        guard let listenPort = Int(listenPort), let destinationPort = Int(destinationPort) else {
            throw ProfileValidationError.invalidPort(field: "Port", value: 0)
        }
        return try .remote(
            id: id,
            name: name,
            listenAddress: listenAddress,
            listenPort: listenPort,
            destinationHost: destinationHost,
            destinationPort: destinationPort
        )
    }
}

public struct DynamicForwardDraft: Identifiable {
    public let id: UUID
    public var name: String
    public var listenAddress: String
    public var listenPort: String

    public init(id: UUID = UUID()) {
        self.id = id
        self.name = ""
        self.listenAddress = "127.0.0.1"
        self.listenPort = ""
    }

    public init(_ dynamicForward: DynamicForward) {
        self.id = dynamicForward.id
        self.name = dynamicForward.name.rawValue
        self.listenAddress = dynamicForward.listenAddress.rawValue
        self.listenPort = String(dynamicForward.listenPort.rawValue)
    }

    public func makePortForward() throws -> PortForward {
        guard let listenPort = Int(listenPort) else {
            throw ProfileValidationError.invalidPort(field: "Listen port", value: 0)
        }
        return try .dynamic(
            id: id,
            name: name,
            listenAddress: listenAddress,
            listenPort: listenPort
        )
    }
}

public enum TunnelProfileSelection {
    public static func draft(
        selecting profileID: UUID?,
        from profiles: [TunnelProfile]
    ) -> TunnelProfileDraft? {
        guard let profileID,
              let profile = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        return TunnelProfileDraft(profile: profile)
    }
}
