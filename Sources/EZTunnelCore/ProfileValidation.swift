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
}
