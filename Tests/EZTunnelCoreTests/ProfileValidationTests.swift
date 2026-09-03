import XCTest
@testable import EZTunnelCore

final class ProfileValidationTests: XCTestCase {
    func testMissingRequiredValuesAreRejected() {
        let profiles = [
            makeProfile(displayName: " "),
            makeProfile(sshHostAlias: ""),
            makeProfile(forwardName: ""),
            makeProfile(destinationHost: ""),
        ]
        for profile in profiles {
            XCTAssertThrowsError(try ProfileValidator.validate(profile)) {
                XCTAssertTrue($0 is ProfileValidationError)
            }
        }
    }

    func testInvalidListenPortsAreRejected() {
        for port in [0, -1, 65_536] {
            XCTAssertThrowsError(try ProfileValidator.validate(makeProfile(listenPort: port))) {
                XCTAssertEqual($0 as? ProfileValidationError, .invalidPort(field: "Listen port", value: port))
            }
        }
    }

    func testInvalidDestinationPortsAreRejected() {
        for port in [0, -1, 65_536] {
            XCTAssertThrowsError(try ProfileValidator.validate(makeProfile(destinationPort: port))) {
                XCTAssertEqual($0 as? ProfileValidationError, .invalidPort(field: "Destination port", value: port))
            }
        }
    }

    func testNonLoopbackListenAddressesAreRejected() {
        for address in ["0.0.0.0", "localhost", "192.168.1.2", ""] {
            XCTAssertThrowsError(try ProfileValidator.validate(makeProfile(listenAddress: address))) {
                XCTAssertEqual($0 as? ProfileValidationError, .invalidListenAddress(address))
            }
        }
    }

    func testExplicitLoopbackListenAddressesAreAccepted() {
        for address in ["127.0.0.1", "::1"] {
            XCTAssertNoThrow(try ProfileValidator.validate(makeProfile(listenAddress: address)))
        }
    }

    func testIPv4LoopbackIsTheDefaultListenAddress() {
        XCTAssertEqual(makeProfile().localForward.listenAddress, "127.0.0.1")
    }

    func testProfileDisplayNamesAreUniqueIgnoringCaseAndWhitespace() {
        let existing = makeProfile(displayName: "Production")
        let duplicate = makeProfile(displayName: " production ")
        XCTAssertThrowsError(try ProfileValidator.validate(duplicate, against: [existing])) {
            XCTAssertEqual($0 as? ProfileValidationError, .duplicateDisplayName(" production "))
        }
    }

    private func makeProfile(
        displayName: String = "Development", sshHostAlias: String = "development",
        forwardName: String = "Web", listenAddress: String = "127.0.0.1",
        listenPort: Int = 8080, destinationHost: String = "localhost",
        destinationPort: Int = 80
    ) -> TunnelProfile {
        TunnelProfile(
            displayName: displayName, sshHostAlias: sshHostAlias,
            localForward: LocalForward(
                name: forwardName, listenAddress: listenAddress, listenPort: listenPort,
                destinationHost: destinationHost, destinationPort: destinationPort
            )
        )
    }
}
