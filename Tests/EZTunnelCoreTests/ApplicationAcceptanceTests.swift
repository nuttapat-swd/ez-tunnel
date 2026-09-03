import Foundation
import XCTest
@testable import EZTunnelCore

final class ApplicationAcceptanceTests: XCTestCase {
    @MainActor
    func testSavedTunnelProfileIsRestoredAfterRelaunch() throws {
        let persistence = InMemoryProfilePersistence()
        let firstLaunch = try EZTunnelApplication(persistence: persistence)
        let profile = makeProfile()
        try firstLaunch.save(profile)
        let relaunched = try EZTunnelApplication(persistence: persistence)
        XCTAssertEqual(relaunched.profiles, [profile])
    }

    @MainActor
    func testMenuActionOpensManagementWindowThroughOperatingSystemAdapter() throws {
        let opener = ManagementWindowSpy()
        let application = try EZTunnelApplication(
            persistence: InMemoryProfilePersistence(), windowOpener: opener
        )
        application.perform(.openManagementWindow)
        XCTAssertEqual(opener.openCount, 1)
    }

    @MainActor
    func testUpdatingProfileCannotReplaceImmutableLocalForwardIdentityOrName() throws {
        let persistence = InMemoryProfilePersistence()
        let application = try EZTunnelApplication(persistence: persistence)
        let original = makeProfile()
        try application.save(original)
        let replacement = TunnelProfile(
            id: original.id,
            displayName: original.displayName,
            sshHostAlias: original.sshHostAlias,
            localForward: LocalForward(
                name: "Replacement", listenPort: 5432,
                destinationHost: "database.internal", destinationPort: 5432
            )
        )

        XCTAssertThrowsError(try application.save(replacement)) {
            XCTAssertEqual($0 as? ProfileStoreError, .immutableLocalForwardChanged)
        }
        XCTAssertEqual(application.profiles, [original])
    }

    @MainActor
    func testPersistedJSONIsVersionedAndContainsDefinitionDataOnly() throws {
        let persistence = InMemoryProfilePersistence()
        let application = try EZTunnelApplication(persistence: persistence)
        try application.save(makeProfile())
        let data = try XCTUnwrap(persistence.data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serializedJSON = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["profiles"])
        for runtimeField in ["runtimeState", "pid", "retryCount", "connectionStatus"] {
            XCTAssertFalse(serializedJSON.contains("\"\(runtimeField)\""))
        }
    }

    private func makeProfile() -> TunnelProfile {
        TunnelProfile(
            displayName: "Production database",
            sshHostAlias: "production",
            localForward: LocalForward(
                name: "PostgreSQL", listenPort: 5432,
                destinationHost: "database.internal", destinationPort: 5432
            )
        )
    }
}

private final class InMemoryProfilePersistence: ProfilePersistence {
    fileprivate var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

@MainActor
private final class ManagementWindowSpy: ManagementWindowOpening {
    private(set) var openCount = 0
    func openManagementWindow() { openCount += 1 }
}
