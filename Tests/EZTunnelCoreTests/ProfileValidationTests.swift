import Foundation
import Testing
@testable import EZTunnelCore

struct ProfileValidationTests {
    @Test
    func sshHostnameIsAlsoUsedAsTunnelProfileDisplayName() throws {
        let localForward = try LocalForward(
            name: "Web", listenPort: 8080, destinationPort: 80
        )

        let profile = try TunnelProfile(
            sshHostname: "development.example.com",
            destinationHost: "localhost",
            localForwards: [localForward]
        )

        #expect(profile.displayName.rawValue == "development.example.com")
        #expect(profile.sshHostname.rawValue == "development.example.com")
        #expect(profile.sshPort.rawValue == 22)
    }

    @Test
    func missingRequiredValuesAreRejectedAtConstruction() {
        #expect(throws: ProfileValidationError.missingValue("Display name")) {
            try makeProfile(displayName: " ")
        }
        #expect(throws: ProfileValidationError.missingValue("SSH hostname")) {
            try makeProfile(sshHostname: "")
        }
        #expect(throws: ProfileValidationError.missingValue("Local Forward name")) {
            try makeProfile(forwardName: "")
        }
    }

    @Test(arguments: ["", "   ", "\n"])
    func blankDestinationHostDefaultsToIPv4Loopback(destinationHost: String) throws {
        let profile = try makeProfile(destinationHost: destinationHost)

        #expect(profile.destinationHost.rawValue == "127.0.0.1")
    }

    @Test
    func omittedDestinationHostDefaultsToIPv4Loopback() throws {
        let profile = try TunnelProfile(
            sshHostname: "development.example.com",
            localForwards: [
                LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )

        #expect(profile.destinationHost.rawValue == "127.0.0.1")
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
                sshHostname: "development.example.com",
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
                sshHostname: "development.example.com",
                destinationHost: "localhost",
                localForwards: [first, second]
            )
        }
    }

    @Test
    func privateKeyAuthenticationRequiresAKeyPath() {
        #expect(throws: ProfileValidationError.privateKeyPathRequired) {
            try TunnelProfile(
                sshHostname: "ssh.example.com",
                authenticationMethod: .privateKey,
                destinationHost: "localhost",
                localForwards: [
                    LocalForward(name: "Web", listenPort: 8080, destinationPort: 80),
                ]
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
        #expect(json["sshHostname"] as? String == "development.example.com")
        #expect(json["sshPort"] as? Int == 22)
        #expect(json["listenAddress"] as? String == "127.0.0.1")
        #expect(json["destinationHost"] as? String == "localhost")
        #expect(forward["listenPort"] as? Int == 8080)
        #expect(forward["listenAddress"] == nil)
        #expect(forward["destinationHost"] == nil)
    }

    private func makeProfile(
        displayName: String = "Development", sshHostname: String = "development.example.com",
        forwardName: String = "Web", listenAddress: String = "127.0.0.1",
        listenPort: Int = 8080, destinationHost: String = "localhost",
        destinationPort: Int = 80
    ) throws -> TunnelProfile {
        try TunnelProfile(
            displayName: displayName, sshHostname: sshHostname,
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
