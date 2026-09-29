import Foundation
import Testing

@testable import EZTunnelAppSupport
@testable import EZTunnelCore

@MainActor
struct ProfileEditingAcceptanceTests {
    @Test
    func editingEverySupportedFieldPersistsToDiskWithStableIdentities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileProfilePersistence(
            fileURL: directory.appendingPathComponent("profiles.json"))
        let application = try EZTunnelApplication(persistence: persistence)
        let original = try TunnelProfile(
            displayName: "Original", sshHostname: "original.example.com",
            portForwards: [
                .local(
                    name: "Local", listenPort: 8080, destinationHost: "web.internal",
                    destinationPort: 80),
                .remote(
                    name: "Remote", listenPort: 9000, destinationHost: "localhost",
                    destinationPort: 9001),
                .dynamic(name: "Dynamic", listenPort: 1080),
            ])
        try application.save(original)
        var draft = try #require(
            TunnelProfileSelection.draft(selecting: original.id, from: application.profiles))
        draft.displayName = "Edited"
        draft.sshHostname = "edited.example.com"
        draft.sshPort = "2222"
        draft.sshUsername = "deploy"
        draft.authenticationMethod = .privateKey
        draft.privateKeyPath = "/fixture/id_ed25519"
        draft.listenAddress = "::1"
        draft.destinationHost = "edited.internal"
        draft.localForwards[0].name = "Edited Local"
        draft.localForwards[0].listenPort = "18080"
        draft.localForwards[0].destinationPort = "8081"
        draft.remoteForwards[0].name = "Edited Remote"
        draft.remoteForwards[0].listenAddress = "::1"
        draft.remoteForwards[0].listenPort = "19000"
        draft.remoteForwards[0].destinationHost = "127.0.0.1"
        draft.remoteForwards[0].destinationPort = "9002"
        draft.dynamicForwards[0].name = "Edited SOCKS"
        draft.dynamicForwards[0].listenAddress = "::1"
        draft.dynamicForwards[0].listenPort = "1081"
        let edited = try draft.makeProfile()
        try application.save(edited)

        let relaunched = try EZTunnelApplication(persistence: persistence)
        let restored = try #require(relaunched.profiles.first)
        #expect(restored == edited)
        #expect(restored.id == original.id)
        #expect(restored.portForwards.map(\.id) == original.portForwards.map(\.id))
        #expect(relaunched.state(of: original.id) == .stopped)
        #expect(!relaunched.configurationChanged(for: original.id))
    }

    @Test
    func editingUsesCreationValidationAndExcludesItsOwnName() throws {
        let persistence = EditingInMemoryPersistence()
        let application = try EZTunnelApplication(persistence: persistence)
        let original = try TunnelProfile(
            displayName: "Web", sshHostname: "ssh.example.com",
            portForwards: [.dynamic(name: "SOCKS", listenPort: 1080)])
        let other = try TunnelProfile(
            displayName: "Other", sshHostname: "other.example.com",
            portForwards: [.dynamic(name: "SOCKS", listenPort: 1081)])
        try application.save(original)
        try application.save(other)
        var valid = TunnelProfileDraft(profile: original)
        valid.displayName = "WEB"
        let updated = try valid.makeProfile()
        try application.save(updated)
        let savedData = persistence.data
        let invalidEdits: [(inout TunnelProfileDraft) -> Void] = [
            { $0.displayName = "other" },
            { $0.sshHostname = "" },
            { $0.sshPort = "0" },
            { $0.dynamicForwards[0].listenAddress = "0.0.0.0" },
            { $0.dynamicForwards[0].listenPort = "65536" },
            { $0.dynamicForwards = [] },
            { draft in
                var forward = DynamicForwardDraft()
                forward.name = "socks"
                forward.listenPort = "1082"
                draft.dynamicForwards.append(forward)
            },
            { draft in
                var forward = DynamicForwardDraft()
                forward.name = "Duplicate endpoint"
                forward.listenPort = "1080"
                draft.dynamicForwards.append(forward)
            },
        ]
        for edit in invalidEdits {
            var draft = valid
            edit(&draft)
            #expect(throws: ProfileValidationError.self) {
                try application.save(draft.makeProfile())
            }
            #expect(application.profiles == [updated, other])
            #expect(persistence.data == savedData)
        }
    }

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
                LocalForward(id: forwardID, name: "Web", listenPort: 8080, destinationPort: 80)
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

        let visibleDraft = try #require(
            TunnelProfileSelection.draft(
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
