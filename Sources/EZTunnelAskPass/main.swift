import AppKit
import Darwin
import EZTunnelCore
import EZTunnelAppSupport

// OpenSSH is the sole consumer of stdout. Never log the prompt or response.
let environment = ProcessInfo.processInfo.environment
guard environment["SSH_ASKPASS_REQUIRE"] == "force",
      environment["SSH_ASKPASS_PROMPT"] != "none",
      let endpoint = environment["EZ_TUNNEL_SSH_ENDPOINT"],
      CommandLine.arguments.count == 2 else { exit(1) }

// A modal dialog must disappear when Stop or Quit terminates its owning ssh.
let owner = getppid()
guard owner > 1 else { exit(1) }
let ownerMonitor = DispatchSource.makeTimerSource(queue: .global())
ownerMonitor.schedule(deadline: .now(), repeating: .milliseconds(100))
ownerMonitor.setEventHandler {
    if getppid() != owner || kill(owner, 0) != 0 { exit(1) }
}
ownerMonitor.resume()

let response = SSHInteraction.response(
    to: CommandLine.arguments[1],
    endpoint: endpoint,
    credentialKind: environment["EZ_TUNNEL_SSH_CREDENTIAL_KIND"].flatMap(SSHCredentialKind.init),
    readCredential: {
        guard let path = environment["EZ_TUNNEL_SSH_CREDENTIAL_PIPE"] else { return nil }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
              info.st_uid == getuid(), unlink(path) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return String(bytes: bytes.prefix(count), encoding: .utf8)
    },
    present: { interaction in
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let secretField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        switch interaction {
        case .hostKey(let host, let keyType, let fingerprint):
            alert.alertStyle = .warning
            alert.messageText = "Trust a new SSH host key?"
            alert.informativeText = "Host: \(host)\nKey type: \(keyType)\nFingerprint: \(fingerprint)\n\n"
                + "Verify this fingerprint with the server administrator before trusting it."
            alert.addButton(withTitle: "Reject")
            alert.addButton(withTitle: "Trust Key")
        case .password, .passphrase:
            alert.messageText = interaction == .password(endpoint: endpoint)
                ? "SSH password" : "SSH private-key passphrase"
            alert.informativeText = "SSH Endpoint: \(endpoint)\nThis entry is used only for this manual connection."
            alert.accessoryView = secretField
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Continue")
            alert.window.initialFirstResponder = secretField
        }
        alert.buttons[0].keyEquivalent = "\u{1b}"
        // Trust is never the default action, including Return.
        alert.buttons[1].keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        if case .hostKey = interaction { return "yes" }
        return secretField.stringValue
    }
)
guard let response, !response.isEmpty, response.utf8.count < 1024,
      !response.contains("\n"), !response.contains("\r"), !response.contains("\0") else { exit(1) }
FileHandle.standardOutput.write(Data(response.utf8))
exit(0)
