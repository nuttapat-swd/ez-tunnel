import Foundation

public protocol ProfilePersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public struct FileProfilePersistence: ProfilePersistence, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> FileProfilePersistence {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return FileProfilePersistence(
            fileURL: root.appendingPathComponent("EZ Tunnel", isDirectory: true)
                .appendingPathComponent("profiles.json", isDirectory: false)
        )
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}
