import Foundation
import XCTest
@testable import EZTunnelCore

final class FileProfilePersistenceTests: XCTestCase {
    func testSavesAndLoadsProfileData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileProfilePersistence(
            fileURL: directory.appendingPathComponent("profiles.json")
        )
        let expected = Data("profile-data".utf8)
        try persistence.save(expected)
        XCTAssertEqual(try persistence.load(), expected)
    }
}
