import Foundation
import EZTunnelCore

package enum SSHInteraction: Equatable {
    case hostKey(host: String, keyType: String, fingerprint: String)
    case password(endpoint: String)
    case passphrase(endpoint: String)

    package static func response(
        to prompt: String,
        endpoint: String,
        credentialKind: SSHCredentialKind?,
        readCredential: () -> String?,
        present: (SSHInteraction) -> String?
    ) -> String? {
        if prompt.hasPrefix("Enter passphrase for key "), prompt.hasSuffix(": ") {
            return (credentialKind == .privateKeyPassphrase ? readCredential() : nil)
                ?? present(.passphrase(endpoint: endpoint))
        }
        if prompt.hasSuffix("'s password: ") {
            return (credentialKind == .password ? readCredential() : nil)
                ?? present(.password(endpoint: endpoint))
        }
        let pattern = #"\AThe authenticity of host '([^'\r\n]+)' can't be established\.\n([A-Z0-9-]+) key fingerprint is (SHA256:[A-Za-z0-9+/]{43})\.\n[\s\S]*Are you sure you want to continue connecting \(yes/no/\[fingerprint\]\)\?\s*\z"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: prompt, range: NSRange(prompt.startIndex..., in: prompt)
              ) else { return nil }
        let fields = (1...3).compactMap { index in
            Range(match.range(at: index), in: prompt).map { String(prompt[$0]) }
        }
        guard fields.count == 3 else { return nil }
        return present(.hostKey(host: fields[0], keyType: fields[1], fingerprint: fields[2])) == "yes"
            ? "yes" : nil
    }
}
