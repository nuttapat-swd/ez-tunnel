import Foundation
import Testing
import EZTunnelCore
@testable import EZTunnelAppSupport

struct SSHInteractionAcceptanceTests {
    @Test(arguments: [true, false])
    func manualAuthenticationUsesKeychainOrASecurePrompt(hasStoredCredential: Bool) {
        for (prompt, kind, interaction) in [
            ("deploy@ssh.example.com's password: ", SSHCredentialKind.password,
             SSHInteraction.password(endpoint: "ssh.example.com:22")),
            ("Enter passphrase for key '/private/path/id_ed25519': ", .privateKeyPassphrase,
             .passphrase(endpoint: "ssh.example.com:22")),
        ] {
            let response = SSHInteraction.response(
                to: prompt, endpoint: "ssh.example.com:22", credentialKind: kind,
                readCredential: { hasStoredCredential ? "synthetic-stored-secret" : nil },
                present: { displayed in
                    #expect(!hasStoredCredential)
                    #expect(displayed == interaction)
                    #expect(!String(describing: displayed).contains("/private/path"))
                    return "synthetic-manual-secret"
                }
            )
            #expect(response == (hasStoredCredential ? "synthetic-stored-secret" : "synthetic-manual-secret"))
        }
    }

    @Test(arguments: [nil, "no", "", "dismissed"] as [String?])
    func rejectingOrDismissingTrustNeverReturnsApproval(decision: String?) {
        let response = SSHInteraction.response(
            to: "The authenticity of host 'ssh.example.com (192.0.2.1)' can't be established.\n"
                + "ED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG.\n"
                + "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
            endpoint: "ssh.example.com:22",
            credentialKind: .password,
            readCredential: { Issue.record("Trust must not consume the password"); return nil },
            present: { _ in decision }
        )
        #expect(response == nil)
    }

    @Test
    func aNewHostKeyDisplaysItsIdentityAndRequiresExplicitApproval() {
        let prompt = "The authenticity of host 'ssh.example.com (192.0.2.1)' can't be established.\n"
            + "ED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG.\n"
            + "This key is not known by any other names.\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        let response = SSHInteraction.response(
            to: prompt,
            endpoint: "ssh.example.com:22",
            credentialKind: nil,
            readCredential: { Issue.record("Trust must never read credentials"); return nil },
            present: { decision in
                #expect(decision == .hostKey(
                    host: "ssh.example.com (192.0.2.1)",
                    keyType: "ED25519",
                    fingerprint: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
                ))
                return "yes"
            }
        )
        #expect(response == "yes")
    }
}
