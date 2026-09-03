import Foundation

public enum ProfileValidationError: Error, Equatable, LocalizedError, Sendable {
    case missingValue(String)
    case invalidPort(field: String, value: Int)
    case invalidListenAddress(String)
    case duplicateDisplayName(String)
    case requiresLocalForward
    case duplicateLocalForwardID(UUID)
    case duplicateLocalForwardName(String)
    case duplicateListenPort(Int)
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
        case .requiresLocalForward:
            "A Tunnel Profile requires at least one Local Forward."
        case .duplicateLocalForwardID(let id):
            "Local Forward identity \(id.uuidString) appears more than once."
        case .duplicateLocalForwardName(let name):
            "A Local Forward named \(name) already exists in this Tunnel Profile."
        case .duplicateListenPort(let port):
            "Listen port \(port) is used more than once in this Tunnel Profile."
        case .privateKeyPathRequired:
            "Select a private key file."
        case .passwordRequired:
            "Enter the SSH password."
        }
    }
}

public enum ProfileValidator {
    public static func validate(_ profile: TunnelProfile, against profiles: [TunnelProfile] = []) throws {
        try validateLocalForwards(profile.localForwards)
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

    public static func validateLocalForwards(_ localForwards: [LocalForward]) throws {
        guard !localForwards.isEmpty else {
            throw ProfileValidationError.requiresLocalForward
        }
        var ids = Set<UUID>()
        var names = Set<String>()
        var listenPorts = Set<Int>()
        for localForward in localForwards {
            guard ids.insert(localForward.id).inserted else {
                throw ProfileValidationError.duplicateLocalForwardID(localForward.id)
            }
            let name = localForward.name.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard names.insert(name).inserted else {
                throw ProfileValidationError.duplicateLocalForwardName(localForward.name.rawValue)
            }
            guard listenPorts.insert(localForward.listenPort.rawValue).inserted else {
                throw ProfileValidationError.duplicateListenPort(localForward.listenPort.rawValue)
            }
        }
    }
}
