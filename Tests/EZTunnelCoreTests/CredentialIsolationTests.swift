import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct CredentialIsolationTests {
    @Test
    func changingFromPrivateKeyToPasswordNeverReusesThePassphrase() throws {
        let credentials = CredentialIsolationStore()
        let application = try EZTunnelApplication(
            persistence: CredentialIsolationPersistence(),
            credentialStore: credentials
        )
        let privateKeyProfile = try makeProfile(authenticationMethod: .privateKey)
        try application.save(privateKeyProfile, credential: "key-passphrase")

        let passwordProfile = try makeProfile(
            id: privateKeyProfile.id,
            authenticationMethod: .password
        )
        #expect(throws: ProfileValidationError.passwordRequired) {
            try application.save(passwordProfile)
        }

        try application.save(passwordProfile, credential: "login-password")
        #expect(credentials[privateKeyProfile.id, .privateKeyPassphrase] == "key-passphrase")
        #expect(credentials[privateKeyProfile.id, .password] == "login-password")
    }

    @Test
    func systemDefaultRemovesEveryCredentialKind() throws {
        let credentials = CredentialIsolationStore()
        let application = try EZTunnelApplication(
            persistence: CredentialIsolationPersistence(),
            credentialStore: credentials
        )
        let passwordProfile = try makeProfile(authenticationMethod: .password)
        try application.save(passwordProfile, credential: "login-password")
        credentials[passwordProfile.id, .privateKeyPassphrase] = "key-passphrase"

        let systemProfile = try makeProfile(
            id: passwordProfile.id,
            authenticationMethod: .systemDefault
        )
        try application.save(systemProfile)

        #expect(credentials[passwordProfile.id, .password] == nil)
        #expect(credentials[passwordProfile.id, .privateKeyPassphrase] == nil)
    }

    private func makeProfile(
        id: UUID = UUID(),
        authenticationMethod: SSHAuthenticationMethod
    ) throws -> TunnelProfile {
        try TunnelProfile(
            id: id,
            sshHostname: "ssh.example.com",
            authenticationMethod: authenticationMethod,
            privateKeyPath: authenticationMethod == .privateKey ? "/tmp/id_ed25519" : nil,
            destinationHost: "localhost",
            localForwards: [
                LocalForward(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: "Web",
                    listenPort: 8080,
                    destinationPort: 80
                ),
            ]
        )
    }
}

private final class CredentialIsolationStore: SSHCredentialStore {
    private var values: [SSHCredentialKey: String] = [:]

    subscript(profileID: UUID, kind: SSHCredentialKind) -> String? {
        get { values[SSHCredentialKey(profileID: profileID, kind: kind)] }
        set { values[SSHCredentialKey(profileID: profileID, kind: kind)] = newValue }
    }

    func credential(for key: SSHCredentialKey) throws -> String? { values[key] }
    func setCredential(_ credential: String, for key: SSHCredentialKey) throws {
        values[key] = credential
    }
    func removeCredential(for key: SSHCredentialKey) throws {
        values[key] = nil
    }
}

private final class CredentialIsolationPersistence: ProfilePersistence {
    private var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
