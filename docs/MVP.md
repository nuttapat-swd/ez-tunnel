# EZ Tunnel MVP

## Product boundary

EZ Tunnel is a macOS menu-bar application for starting and supervising saved SSH tunnel profiles. The first release is macOS-only, is distributed directly with Developer ID signing and notarization, and uses Sparkle 2 with a signed feed for user-approved updates.

Closing the management window leaves the menu-bar application and its tunnels running. Explicitly quitting EZ Tunnel stops every tunnel owned by the application.

## Tunnel profiles

Each Tunnel Profile has:

- an immutable UUID;
- a case-insensitively unique display name;
- exactly one OpenSSH `Host` alias;
- an auto-start setting; and
- one shared loopback listen address and destination host for its Local Forwards; and
- one or more Port Forwards, started and stopped as a unit.

Each Port Forward has an immutable UUID and a display name that is case-insensitively unique within its profile. It uses one of these modes:

- Local (`-L`): listen port and destination port, using the Tunnel Profile's shared loopback listen address and destination host;
- Remote (`-R`): remote loopback listen address, remote listen port, destination host, and destination port; or
- Dynamic (`-D`): loopback listen address and listen port.

Every port is explicit and in the range `1...65535`; automatic port allocation is not supported. Listen addresses are limited to `127.0.0.1` and `::1`, with `127.0.0.1` as the default. Wildcard and externally reachable bind addresses are not supported.

Duplicate listen endpoints within one profile are invalid. Profiles may reuse an endpoint because they can be run at different times. If an Active Profile already owns an endpoint, starting another profile that needs it fails with an explanation naming the conflicting profile. For an external process conflict, the app shows the PID and process name when macOS makes them available.

## OpenSSH integration

EZ Tunnel launches and supervises `/usr/bin/ssh`; one SSH process is owned by each Active Profile. Connections are not shared between profiles.

The referenced `Host` alias is resolved by OpenSSH configuration, including `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump`, wildcard rules, `Match`, and `Include`. Jump Host chains therefore remain owned by OpenSSH configuration. The profile editor offers best-effort alias autocomplete but accepts aliases it could not discover, and uses `ssh -G` for authoritative resolution.

The app generates only the forwarding and lifecycle arguments it understands. It provides no arbitrary SSH argument or shell-command field; other SSH behavior belongs in OpenSSH configuration.

Saving requires static validation but never requires network access. A separate Test Connection action verifies alias resolution, Jump Hosts, host trust, and authentication without opening Port Forwards. Starting a profile performs the real bind checks.

## Lifecycle and state

The primary state flow is:

```text
Stopped -> Connecting -> Connected
Connected -> Reconnecting -> Connected
Connecting/Reconnecting -> Needs Attention
Connecting/Connected/Reconnecting/Needs Attention -> Stopping -> Stopped
```

A profile becomes Connected only after its SSH connection and every Port Forward are ready. Startup is all-or-nothing: if one forward cannot bind, the complete profile connection is stopped and the error identifies the failing forward and endpoint. Connected does not imply that an application behind the tunnel is healthy; no destination service probes are performed.

Starting a profile makes it Active until the user stops it or quits EZ Tunnel. Temporary failures such as network loss, timeout, or server unavailability enter Reconnecting and retry with exponential backoff (initially `1, 2, 5, 10, 30` seconds, capped at 30 seconds). Problems requiring intervention—including unavailable credentials, host-key decisions, invalid configuration, unresolved aliases, and occupied ports—enter Needs Attention and pause retries.

Auto-start is configured per profile. When at least one profile is configured for auto-start, EZ Tunnel runs as a macOS login item and starts those profiles without interactive prompts. Profiles started manually also reconnect until explicitly stopped, but they do not become auto-start profiles.

On sleep, the app preserves Active intent. After wake it terminates potentially half-open owned processes, waits for network availability, and reconnects with current saved configuration. A small recovery journal, separate from profile data and cleared on clean shutdown, allows a restarted app to recover Active intent after a crash.

Every child SSH process carries app-specific ownership metadata. Crash recovery must verify both that metadata and process identity before terminating a stale process; EZ Tunnel never kills SSH processes merely because their executable is `/usr/bin/ssh`.

## Configuration changes

Editing a connected profile or its referenced OpenSSH configuration does not interrupt the current connection. The UI displays a Configuration Changed badge and offers Restart Now. The latest saved values take effect on a user-requested restart or the next reconnect.

Profile data is stored as atomically written, schema-versioned JSON in Application Support. Runtime state, PIDs, retry counters, and connection status are not fields in the profile schema.

Exported profiles contain no credentials. Imported profiles are statically validated, shown for review, and always imported with auto-start disabled regardless of the source file.

Deleting an Active Profile requires confirmation, stops its owned tunnel, and then removes it. Undo is available during the current application session; closing the app makes the deletion permanent.

## Trust and credentials

EZ Tunnel does not store SSH passwords, read or store private keys, or replace OpenSSH credential management. Authentication uses OpenSSH, ssh-agent, and macOS Keychain. Manual starts may show a system password or passphrase prompt. Auto-start and background reconnect never prompt; they enter Needs Attention when interaction is required.

New SSH host keys require explicit manual approval after showing host, key type, and fingerprint. Unattended attempts never accept a key. A changed host key is presented as a higher-severity security event and cannot be replaced with one click.

## User experience and diagnostics

The menu bar provides profile status and Start, Stop, Restart, and Open Management Window actions. The management window provides profile editing, Test Connection, import/export, diagnostics, and update controls.

macOS notifications are sent when a profile Needs Attention, when auto-start cannot connect, and when a profile recovers after an outage longer than one minute. Individual retries and brief interruptions do not notify. Notifications can be disabled per profile.

Local diagnostic logs rotate after seven days or 20 MB total, whichever comes first. They may contain state transitions, exit status, and redacted errors, but never traffic payloads, authentication input, full private-key paths, or complete SSH argument lists. Export Diagnostics provides a preview before writing an export.

No usage analytics or SSH operational metadata leaves the machine. Crash reporting is opt-in and redacts SSH arguments, filesystem paths, and connection metadata. The signed Sparkle update check is the only default outbound application service beyond the SSH connections the user requests.

## Explicitly outside the MVP

- schedules;
- cloud sync and team sharing;
- a CLI;
- traffic inspection or payload logging;
- destination service health checks;
- connection multiplexing across profiles;
- Windows or Linux support; and
- listen addresses reachable by other machines.
