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

    @Test
    func editorDraftPreservesEveryPortForwardModeAndItsModeSpecificFields() throws {
        let localID = UUID()
        let remoteID = UUID()
        let dynamicID = UUID()
        let profile = try TunnelProfile(
            displayName: "Complete",
            sshHostname: "ssh.example.com",
            portForwards: [
                PortForward.local(
                    id: localID,
                    name: "Database",
                    listenPort: 15432,
                    destinationHost: "database.internal",
                    destinationPort: 5432
                ),
                PortForward.remote(
                    id: remoteID,
                    name: "Webhook",
                    listenAddress: "::1",
                    listenPort: 19000,
                    destinationHost: "127.0.0.1",
                    destinationPort: 9000
                ),
                PortForward.dynamic(
                    id: dynamicID,
                    name: "SOCKS",
                    listenPort: 1080
                ),
            ]
        )

        let draft = TunnelProfileDraft(profile: profile)
        let rebuilt = try draft.makeProfile()

        #expect(rebuilt == profile)
        #expect(draft.localForwards.map(\.id) == [localID])
        #expect(draft.remoteForwards.map(\.id) == [remoteID])
        #expect(draft.remoteForwards.map(\.listenAddress) == ["::1"])
        #expect(draft.remoteForwards.map(\.destinationHost) == ["127.0.0.1"])
        #expect(draft.dynamicForwards.map(\.id) == [dynamicID])
        #expect(draft.dynamicForwards.map(\.listenPort) == ["1080"])
    }
}

private final class EditingInMemoryPersistence: ProfilePersistence {
    var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
