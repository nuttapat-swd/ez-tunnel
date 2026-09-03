import Foundation
import Testing
@testable import EZTunnelCore

struct ProfileValidationTests {
    @Test
    func sshHostAliasIsAlsoUsedAsTunnelProfileDisplayName() throws {
        let localForward = try LocalForward(
            name: "Web", listenPort: 8080, destinationPort: 80
        )

        let profile = try TunnelProfile(
            sshHostAlias: "development",
            destinationHost: "localhost",
            localForwards: [localForward]
        )

        #expect(profile.displayName.rawValue == "development")
        #expect(profile.sshHostAlias.rawValue == "development")
    }

    @Test
    func missingRequiredValuesAreRejectedAtConstruction() {
        #expect(throws: ProfileValidationError.missingValue("Display name")) {
            try makeProfile(displayName: " ")
        }
        #expect(throws: ProfileValidationError.missingValue("SSH Host alias")) {
            try makeProfile(sshHostAlias: "")
        }
        #expect(throws: ProfileValidationError.missingValue("Local Forward name")) {
            try makeProfile(forwardName: "")
        }
        #expect(throws: ProfileValidationError.missingValue("Destination host")) {
            try makeProfile(destinationHost: "")
        }
    }

    @Test(arguments: [0, -1, 65_536])
    func invalidListenPortsAreRejectedAtConstruction(port: Int) {
        #expect(throws: ProfileValidationError.invalidPort(field: "Listen port", value: port)) {
            try makeProfile(listenPort: port)
        }
    }

    @Test(arguments: [0, -1, 65_536])
    func invalidDestinationPortsAreRejectedAtConstruction(port: Int) {
        #expect(throws: ProfileValidationError.invalidPort(field: "Destination port", value: port)) {
            try makeProfile(destinationPort: port)
        }
    }

    @Test(arguments: ["0.0.0.0", "localhost", "192.168.1.2", ""])
    func nonLoopbackListenAddressesAreRejectedAtConstruction(address: String) {
        #expect(throws: ProfileValidationError.invalidListenAddress(address)) {
            try makeProfile(listenAddress: address)
        }
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func explicitLoopbackListenAddressesAreAccepted(address: String) throws {
        _ = try makeProfile(listenAddress: address)
    }

    @Test
    func ipv4LoopbackIsTheDefaultListenAddress() throws {
        #expect(try makeProfile().listenAddress == .ipv4)
    }

    @Test
    func profileDisplayNamesAreUniqueIgnoringCaseAndWhitespace() throws {
        let existing = try makeProfile(displayName: "Production")
        let duplicate = try makeProfile(displayName: " production ")
        #expect(throws: ProfileValidationError.duplicateDisplayName(" production ")) {
            try ProfileValidator.validate(duplicate, against: [existing])
        }
    }

    @Test
    func tunnelProfileRequiresAtLeastOneLocalForward() {
        #expect(throws: ProfileValidationError.requiresLocalForward) {
            try TunnelProfile(
                sshHostAlias: "development",
                destinationHost: "localhost",
                localForwards: []
            )
        }
    }

    @Test
    func localForwardsCannotReuseAListenPort() throws {
        let first = try LocalForward(name: "Web", listenPort: 8080, destinationPort: 80)
        let second = try LocalForward(name: "Admin", listenPort: 8080, destinationPort: 8081)

        #expect(throws: ProfileValidationError.duplicateListenPort(8080)) {
            try TunnelProfile(
                sshHostAlias: "development",
                destinationHost: "localhost",
                localForwards: [first, second]
            )
        }
    }

    @Test
    func validatedValuesPersistAsSchemaPrimitives() throws {
        let data = try JSONEncoder().encode(makeProfile())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let forwards = try #require(json["localForwards"] as? [[String: Any]])
        let forward = try #require(forwards.first)

        #expect(json["displayName"] as? String == "Development")
        #expect(json["sshHostAlias"] as? String == "development")
        #expect(json["listenAddress"] as? String == "127.0.0.1")
        #expect(json["destinationHost"] as? String == "localhost")
        #expect(forward["listenPort"] as? Int == 8080)
        #expect(forward["listenAddress"] == nil)
        #expect(forward["destinationHost"] == nil)
    }

    private func makeProfile(
        displayName: String = "Development", sshHostAlias: String = "development",
        forwardName: String = "Web", listenAddress: String = "127.0.0.1",
        listenPort: Int = 8080, destinationHost: String = "localhost",
        destinationPort: Int = 80
    ) throws -> TunnelProfile {
        try TunnelProfile(
            displayName: displayName, sshHostAlias: sshHostAlias,
            listenAddress: listenAddress,
            destinationHost: destinationHost,
            localForwards: [
                LocalForward(
                    name: forwardName, listenPort: listenPort,
                    destinationPort: destinationPort
                ),
            ]
        )
    }
}
