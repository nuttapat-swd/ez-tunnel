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
            destinationHost: original.destinationHost.rawValue,
            localForwards: [
                LocalForward(name: "Replacement", listenPort: 5432, destinationPort: 5432),
            ]
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

        #expect(object["schemaVersion"] as? Int == 2)
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
            "schemaVersion": 2,
            "profiles": [encodedProfile, encodedProfile],
        ])
        let persistence = InMemoryProfilePersistence(data: data)

        #expect(throws: ProfileStoreError.duplicateTunnelProfileID(profile.id)) {
            try EZTunnelApplication(persistence: persistence)
        }
    }

    @Test
    func schemaVersionOneProfileMigratesToSharedHostsAndLocalForwards() throws {
        let profileID = UUID()
        let forwardID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "profiles": [[
                "id": profileID.uuidString,
                "displayName": "legacy",
                "sshHostAlias": "legacy",
                "localForward": [
                    "id": forwardID.uuidString,
                    "name": "Web",
                    "listenAddress": "127.0.0.1",
                    "listenPort": 8080,
                    "destinationHost": "localhost",
                    "destinationPort": 80,
                ],
            ]],
        ])

        let application = try EZTunnelApplication(
            persistence: InMemoryProfilePersistence(data: data)
        )
        let profile = try #require(application.profiles.first)

        #expect(profile.id == profileID)
        #expect(profile.listenAddress == .ipv4)
        #expect(profile.destinationHost.rawValue == "localhost")
        #expect(profile.localForwards.map(\.id) == [forwardID])
    }

    private func makeProfile() throws -> TunnelProfile {
        try TunnelProfile(
            displayName: "Production database",
            sshHostAlias: "production",
            destinationHost: "database.internal",
            localForwards: [
                LocalForward(name: "PostgreSQL", listenPort: 5432, destinationPort: 5432),
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )
    }
}

private final class InMemoryProfilePersistence: ProfilePersistence {
    var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
