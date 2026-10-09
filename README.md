# EZ Tunnel

EZ Tunnel is a native macOS menu-bar application for defining Tunnel Profiles.

## Development

The project requires macOS 13 or later and a Swift toolchain that matches the installed macOS SDK.

Build and open the native application bundle:

```sh
make run
```

Run verification:

```sh
make smoke-test
make test
```

The Swift test suite requires full Xcode; the standalone Command Line Tools package
does not include a compatible test runtime.

Profile definitions are stored as schema-versioned JSON at
`~/Library/Application Support/EZ Tunnel/profiles.json`. Writes use Foundation's
atomic file-writing option. Tunnel Profile JSON contains definitions only; runtime
state is kept separately and is not part of the persisted profile schema.

Active intent and child-process ownership are stored separately in `recovery.json`
beside the profile definitions. A clean quit stops the children and clears this
journal. Following a crash, either manual or login launch recovers Active Profiles
using their current saved definitions without prompting for credentials. Password
authentication and other failures requiring interaction pause in **Needs Attention**.

Recovery verifies the process owner, executable, start time, and unique ControlPath
before requesting shutdown through its OpenSSH control socket. The connected socket
also verifies its peer PID; recovery never sends a signal to a PID read from disk.
Missing processes, reused PIDs, and mismatched ownership are left alone. If a verified
child cannot be safely closed, its Profile pauses in **Needs Attention** and the
journal entry is retained, including across quit, for a later cleanup attempt.

Each Tunnel Profile stores its SSH hostname, port, optional username, and
authentication method directly. Passwords and private-key passphrases are stored in
macOS Keychain and are never written to profile JSON.

Saved edits do not interrupt an Active Profile. **Configuration Changed** appears
beside its lifecycle state when saved values differ from the current attempt.
**Restart Now**, in the management window or menu bar, stops the owned process and
applies the latest saved values. Automatic reconnect also uses those values;
unsaved editor changes are not applied. Saving the original profile values again
clears the badge.

Following ADR 0008, connections use the profile's explicit SSH Endpoint and ignore
external OpenSSH configuration (`-F /dev/null`). The external SSH Host change
criteria in issue #9 belong to the superseded alias-based design and do not apply.
