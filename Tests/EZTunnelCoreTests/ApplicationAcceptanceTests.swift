import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct ApplicationAcceptanceTests {
    @Test
    func savedTunnelProfileIsRestoredAfterRelaunch() throws {
        let persistence = InMemoryProfilePersistence()
        let firstLaunch = try EZTunnelApplication(persistence: persistence)
        let profile = try makeProfile()

        try firstLaunch.save(profile)
        let relaunched = try EZTunnelApplication(persistence: persistence)

        #expect(relaunched.profiles == [profile])
    }

    @Test
    func updatingProfileCannotReplaceImmutableLocalForwardIdentityOrName() throws {
        let persistence = InMemoryProfilePersistence()
        let application = try EZTunnelApplication(persistence: persistence)
        let original = try makeProfile()
        try application.save(original)
        let replacement = try TunnelProfile(
            id: original.id,
            displayName: original.displayName.rawValue,
            sshHostAlias: original.sshHostAlias.rawValue,
            localForward: LocalForward(
                name: "Replacement", listenPort: 5432,
                destinationHost: "database.internal", destinationPort: 5432
            )
        )

        #expect(throws: ProfileStoreError.immutableLocalForwardChanged) {
            try application.save(replacement)
        }
        #expect(application.profiles == [original])
    }

    @Test
    func persistedJSONIsVersionedAndContainsDefinitionDataOnly() throws {
        let persistence = InMemoryProfilePersistence()
        let application = try EZTunnelApplication(persistence: persistence)
        try application.save(makeProfile())
        let data = try #require(persistence.data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serializedJSON = String(decoding: data, as: UTF8.self)

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["profiles"] != nil)
        for runtimeField in ["runtimeState", "pid", "retryCount", "connectionStatus"] {
            #expect(!serializedJSON.contains("\"\(runtimeField)\""))
        }
    }

    @Test
    func relaunchRejectsDuplicateTunnelProfileIdentities() throws {
        let profile = try makeProfile()
        let encodedProfile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "profiles": [encodedProfile, encodedProfile],
        ])
        let persistence = InMemoryProfilePersistence(data: data)

        #expect(throws: ProfileStoreError.duplicateTunnelProfileID(profile.id)) {
            try EZTunnelApplication(persistence: persistence)
        }
    }

    private func makeProfile() throws -> TunnelProfile {
        try TunnelProfile(
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
    var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
