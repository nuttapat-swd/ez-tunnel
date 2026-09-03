# EZ Tunnel

EZ Tunnel is a native macOS menu-bar application for defining SSH Tunnel Profiles.

## Development

The project requires macOS 13 or later and a Swift toolchain that matches the installed macOS SDK.

```sh
swift test
swift run EZTunnel
```

Profile definitions are stored as schema-versioned JSON at
`~/Library/Application Support/EZ Tunnel/profiles.json`. Writes use Foundation's
atomic file-writing option. Profiles contain definitions only; runtime state belongs
to later lifecycle work and is not part of the persisted schema.
