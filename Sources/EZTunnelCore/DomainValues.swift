import Foundation

public protocol ValidatedStringValue: Codable {
    var rawValue: String { get }
    init(rawValue: String) throws
}

public extension ValidatedStringValue {
    init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TunnelProfileName: ValidatedStringValue, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try requireValue(rawValue, field: "Display name")
        self.rawValue = rawValue
    }
}

public struct SSHHostAlias: ValidatedStringValue, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try requireValue(rawValue, field: "SSH Host alias")
        self.rawValue = rawValue
    }
}

public struct LocalForwardName: ValidatedStringValue, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try requireValue(rawValue, field: "Local Forward name")
        self.rawValue = rawValue
    }
}

public struct DestinationHost: ValidatedStringValue, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try requireValue(rawValue, field: "Destination host")
        self.rawValue = rawValue
    }
}

public enum LoopbackAddress: String, Codable, CaseIterable, Sendable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"

    public init(validating value: String) throws {
        guard let address = Self(rawValue: value) else {
            throw ProfileValidationError.invalidListenAddress(value)
        }
        self = address
    }
}

public struct PortNumber: Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) throws {
        guard (1...65_535).contains(rawValue) else {
            throw ProfileValidationError.invalidPort(field: "Port", value: rawValue)
        }
        self.rawValue = rawValue
    }

    init(_ value: Int, field: String) throws {
        guard (1...65_535).contains(value) else {
            throw ProfileValidationError.invalidPort(field: field, value: value)
        }
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private func requireValue(_ value: String, field: String) throws {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ProfileValidationError.missingValue(field)
    }
}
