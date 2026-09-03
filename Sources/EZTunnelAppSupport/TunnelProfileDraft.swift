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
    }

    public mutating func addLocalForward() {
        localForwards.append(LocalForwardDraft())
    }

    public mutating func removeLocalForward(id: UUID) {
        localForwards.removeAll { $0.id == id }
    }

    public func makeProfile() throws -> TunnelProfile {
        guard let sshPort = Int(sshPort) else {
            throw ProfileValidationError.invalidPort(field: "SSH port", value: 0)
        }
        return try TunnelProfile(
            id: profileID,
            displayName: displayName,
            sshHostname: sshHostname,
            sshPort: sshPort,
            sshUsername: sshUsername,
            authenticationMethod: authenticationMethod,
            privateKeyPath: privateKeyPath,
            listenAddress: listenAddress,
            destinationHost: destinationHost,
            localForwards: try localForwards.map { try $0.makeLocalForward() }
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
