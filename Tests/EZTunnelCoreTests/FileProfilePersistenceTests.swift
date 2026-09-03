import Foundation
import Testing
@testable import EZTunnelCore

struct FileProfilePersistenceTests {
    @Test
    func savesAndLoadsProfileData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileProfilePersistence(
            fileURL: directory.appendingPathComponent("profiles.json")
        )
        let expected = Data("profile-data".utf8)

        try persistence.save(expected)

        #expect(try persistence.load() == expected)
    }
}
