import Foundation

public enum ProfileValidationError: Error, Equatable, LocalizedError, Sendable {
    case missingValue(String)
    case invalidPort(field: String, value: Int)
    case invalidListenAddress(String)
    case duplicateDisplayName(String)

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
        }
    }
}

public enum ProfileValidator {
    public static func validate(_ profile: TunnelProfile, against profiles: [TunnelProfile] = []) throws {
        try require(profile.displayName, field: "Display name")
        try require(profile.sshHostAlias, field: "SSH Host alias")
        try require(profile.localForward.name, field: "Local Forward name")
        try require(profile.localForward.destinationHost, field: "Destination host")

        guard (1...65_535).contains(profile.localForward.listenPort) else {
            throw ProfileValidationError.invalidPort(
                field: "Listen port",
                value: profile.localForward.listenPort
            )
        }
        guard (1...65_535).contains(profile.localForward.destinationPort) else {
            throw ProfileValidationError.invalidPort(
                field: "Destination port",
                value: profile.localForward.destinationPort
            )
        }
        guard ["127.0.0.1", "::1"].contains(profile.localForward.listenAddress) else {
            throw ProfileValidationError.invalidListenAddress(profile.localForward.listenAddress)
        }

        let normalizedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles.contains(where: {
            $0.id != profile.id
                && $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            throw ProfileValidationError.duplicateDisplayName(profile.displayName)
        }
    }

    private static func require(_ value: String, field: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileValidationError.missingValue(field)
        }
    }
}
