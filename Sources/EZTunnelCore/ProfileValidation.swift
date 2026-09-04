import Foundation

public enum ProfileValidationError: Error, Equatable, LocalizedError, Sendable {
    case missingValue(String)
    case invalidPort(field: String, value: Int)
    case invalidListenAddress(String)
    case duplicateDisplayName(String)
    case requiresPortForward
    case duplicatePortForwardID(UUID)
    case duplicatePortForwardName(String)
    case duplicateListenEndpoint(address: String, port: Int)
    case localForwardsRequireSharedHosts
    case privateKeyPathRequired
    case passwordRequired

    public var errorDescription: String? {
        switch self {
        case .missingValue(let field):
            "\(field) is required."
        case .invalidPort(let field, let value):
            "\(field) must be between 1 and 65535 (received \(value))."
        case .invalidListenAddress(let address):
            "Listen address must be 127.0.0.1 or ::1 (received \(address))."
        case .duplicateDisplayName(let name):
            "A Tunnel Profile named \(name) already exists."
        case .requiresPortForward:
            "A Tunnel Profile requires at least one Port Forward."
        case .duplicatePortForwardID(let id):
            "Port Forward identity \(id.uuidString) appears more than once."
        case .duplicatePortForwardName(let name):
            "A Port Forward named \(name) already exists in this Tunnel Profile."
        case .duplicateListenEndpoint(let address, let port):
            "Listen endpoint \(address):\(port) is used more than once in this Tunnel Profile."
        case .localForwardsRequireSharedHosts:
            "Local Forwards in one Tunnel Profile must share the same hosts."
        case .privateKeyPathRequired:
            "Select a private key file."
        case .passwordRequired:
            "Enter the SSH password."
        }
    }
}

public enum ProfileValidator {
    public static func validate(_ profile: TunnelProfile, against profiles: [TunnelProfile] = []) throws {
        try validatePortForwards(profile.portForwards)
        if profile.authenticationMethod == .privateKey, profile.privateKeyPath == nil {
            throw ProfileValidationError.privateKeyPathRequired
        }
        let normalizedName = profile.displayName.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles.contains(where: {
            $0.id != profile.id
                && $0.displayName.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            throw ProfileValidationError.duplicateDisplayName(profile.displayName.rawValue)
        }
    }

    public static func validatePortForwards(_ portForwards: [PortForward]) throws {
        guard !portForwards.isEmpty else {
            throw ProfileValidationError.requiresPortForward
        }
        var ids = Set<UUID>()
        var names = Set<String>()
        var endpoints = Set<ListenEndpoint>()
        for portForward in portForwards {
            guard ids.insert(portForward.id).inserted else {
                throw ProfileValidationError.duplicatePortForwardID(portForward.id)
            }
            let name = portForward.name.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard names.insert(name).inserted else {
                throw ProfileValidationError.duplicatePortForwardName(portForward.name.rawValue)
            }
            let endpoint = ListenEndpoint(
                address: portForward.listenAddress.rawValue,
                port: portForward.listenPort.rawValue
            )
            guard endpoints.insert(endpoint).inserted else {
                throw ProfileValidationError.duplicateListenEndpoint(
                    address: endpoint.address,
                    port: endpoint.port
                )
            }
        }
    }
}

private struct ListenEndpoint: Hashable {
    let address: String
    let port: Int
}
