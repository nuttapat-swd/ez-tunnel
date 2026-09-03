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
            sshHostname: original.sshHostname.rawValue,
            sshPort: original.sshPort.rawValue,
            sshUsername: original.sshUsername?.rawValue,
            authenticationMethod: original.authenticationMethod,
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

        #expect(object["schemaVersion"] as? Int == 3)
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
            "schemaVersion": 3,
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

    @Test
    func passwordIsStoredInCredentialStoreAndNeverProfileJSON() throws {
        let persistence = InMemoryProfilePersistence()
        let credentials = InMemoryCredentialStore()
        let application = try EZTunnelApplication(
            persistence: persistence,
            credentialStore: credentials
        )
        let profile = try TunnelProfile(
            sshHostname: "ssh.example.com",
            sshUsername: "deploy",
            authenticationMethod: .password,
            destinationHost: "localhost",
            localForwards: [
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )

        try application.save(profile, credential: " secret with spaces ")

        #expect(try credentials.credential(for: profile.id) == " secret with spaces ")
        let json = String(decoding: try #require(persistence.data), as: UTF8.self)
        #expect(!json.contains("secret with spaces"))
    }

    @Test
    func schemaVersionTwoProfileMigratesToDirectSSHEndpoint() throws {
        let profileID = UUID()
        let forwardID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "profiles": [[
                "id": profileID.uuidString,
                "displayName": "legacy-alias",
                "sshHostAlias": "legacy-alias",
                "listenAddress": "127.0.0.1",
                "destinationHost": "localhost",
                "localForwards": [[
                    "id": forwardID.uuidString,
                    "name": "Web",
                    "listenPort": 8080,
                    "destinationPort": 80,
                ]],
            ]],
        ])

        let application = try EZTunnelApplication(
            persistence: InMemoryProfilePersistence(data: data)
        )
        let profile = try #require(application.profiles.first)

        #expect(profile.sshHostname.rawValue == "legacy-alias")
        #expect(profile.sshPort.rawValue == 22)
        #expect(profile.authenticationMethod == .systemDefault)
    }

    @Test
    func passwordAuthenticationRequiresAStoredOrSuppliedPassword() throws {
        let application = try EZTunnelApplication(
            persistence: InMemoryProfilePersistence(),
            credentialStore: InMemoryCredentialStore()
        )
        let profile = try TunnelProfile(
            sshHostname: "ssh.example.com",
            authenticationMethod: .password,
            destinationHost: "localhost",
            localForwards: [
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )

        #expect(throws: ProfileValidationError.passwordRequired) {
            try application.save(profile)
        }
    }

    private func makeProfile() throws -> TunnelProfile {
        try TunnelProfile(
            displayName: "Production database",
            sshHostname: "production.example.com",
            sshUsername: "deploy",
            destinationHost: "database.internal",
            localForwards: [
                LocalForward(name: "PostgreSQL", listenPort: 5432, destinationPort: 5432),
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )
    }
}

private final class InMemoryCredentialStore: SSHCredentialStore {
    private var credentials = [UUID: String]()
    func credential(for profileID: UUID) throws -> String? { credentials[profileID] }
    func setCredential(_ credential: String, for profileID: UUID) throws {
        credentials[profileID] = credential
    }
    func removeCredential(for profileID: UUID) throws {
        credentials[profileID] = nil
    }
}

private final class InMemoryProfilePersistence: ProfilePersistence {
    var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
