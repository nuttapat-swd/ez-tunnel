import Foundation
import Testing
@testable import EZTunnelAppSupport
@testable import EZTunnelCore

@MainActor
struct ProfileEditingAcceptanceTests {
    @Test
    func savedProfileCanBeEditedWithoutChangingItsIdentity() throws {
        let persistence = EditingInMemoryPersistence()
        let application = try EZTunnelApplication(persistence: persistence)
        let profileID = UUID()
        let forwardID = UUID()
        let original = try TunnelProfile(
            id: profileID,
            displayName: "Production",
            sshHostname: "old.example.com",
            destinationHost: "old.internal",
            localForwards: [
                LocalForward(id: forwardID, name: "Web", listenPort: 8080, destinationPort: 80),
            ]
        )
        try application.save(original)

        let edited = try TunnelProfile(
            id: profileID,
            displayName: "Production edited",
            sshHostname: "new.example.com",
            sshPort: 2222,
            sshUsername: "deploy",
            listenAddress: "::1",
            destinationHost: "new.internal",
            localForwards: [
                LocalForward(
                    id: forwardID,
                    name: "Web edited",
                    listenPort: 8081,
                    destinationPort: 8080
                ),
                LocalForward(name: "Database", listenPort: 5432, destinationPort: 5432),
            ]
        )
        try application.save(edited)

        let relaunched = try EZTunnelApplication(persistence: persistence)
        let restored = try #require(relaunched.profiles.first)
        #expect(restored == edited)
        #expect(restored.id == profileID)
        #expect(restored.localForwards.first?.id == forwardID)

        let visibleDraft = try #require(TunnelProfileSelection.draft(
            selecting: profileID,
            from: relaunched.profiles
        ))
        #expect(visibleDraft.profileID == profileID)
        #expect(visibleDraft.displayName == "Production edited")
        #expect(visibleDraft.sshHostname == "new.example.com")
        #expect(visibleDraft.sshPort == "2222")
        #expect(visibleDraft.sshUsername == "deploy")
        #expect(visibleDraft.listenAddress == "::1")
        #expect(visibleDraft.destinationHost == "new.internal")
        #expect(visibleDraft.localForwards.map(\.id).first == forwardID)
        #expect(visibleDraft.localForwards.map(\.name) == ["Web edited", "Database"])
        #expect(visibleDraft.localForwards.map(\.listenPort) == ["8081", "5432"])
        #expect(visibleDraft.localForwards.map(\.destinationPort) == ["8080", "5432"])
    }
}

private final class EditingInMemoryPersistence: ProfilePersistence {
    var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
