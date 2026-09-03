# Use OpenSSH configuration as the connection source of truth

Status: Superseded by ADR 0008.

Each Tunnel Profile will reference a `Host` alias resolved from the user's OpenSSH configuration rather than duplicating host, user, port, identity, and ProxyJump settings inside EZ Tunnel. This prevents conflicting precedence rules and lets `/usr/bin/ssh` retain its established authentication and routing behavior; the trade-off is that users must first configure a working SSH host outside the application.
