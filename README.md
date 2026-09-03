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

Each Tunnel Profile stores its SSH hostname, port, optional username, and
authentication method directly. Passwords and private-key passphrases are stored in
macOS Keychain and are never written to profile JSON.
