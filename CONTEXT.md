# EZ Tunnel

EZ Tunnel is a desktop application for defining and operating SSH tunnels that expose network destinations through local, remote, or dynamic forwarding.

## Language

**Tunnel Profile**:
A saved definition with a stable identity and a case-insensitively unique display name that contains exactly one **SSH Endpoint**, one authentication method, and one or more **Port Forwards** that are started and stopped together. Its Local Forwards share one loopback listen address and one destination host.
_Avoid_: Config, connection

**Auto-start Profile**:
A **Tunnel Profile** marked to start when EZ Tunnel launches automatically at macOS login. Profiles without this setting remain available for manual start.
_Avoid_: Always-on tunnel

**Stopped**:
The state of a **Tunnel Profile** that the user does not currently intend to run.
_Avoid_: Disconnected

**Active Profile**:
A **Tunnel Profile** the user has started and has not stopped. It remains active while temporarily disconnected and is reconnected automatically until the user stops it or quits EZ Tunnel.
_Avoid_: Connected profile, running process

**Connecting**:
The state of an **Active Profile** making its initial attempt to establish its SSH connection and all Port Forwards.
_Avoid_: Reconnecting

**Needs Attention**:
The state of an **Active Profile** blocked by a problem that automatic retry cannot resolve, such as an unavailable credential, untrusted host key, invalid configuration, or occupied port. Automatic attempts pause until the user acts.
_Avoid_: Failed, disconnected

**Reconnecting**:
The state of an **Active Profile** retrying after a temporary connection failure such as network loss, timeout, or an unavailable SSH server.
_Avoid_: Needs Attention, failed

**Connected Profile**:
An **Active Profile** whose SSH connection and every **Port Forward** are ready. A profile is never considered connected when only some of its Port Forwards succeeded.
_Avoid_: Partially connected

**Stopping**:
The state of an **Active Profile** closing its Port Forwards and SSH connection after the user stops it or quits EZ Tunnel.
_Avoid_: Stopped

**Configuration Changed**:
A badge indicating that an active **Tunnel Profile** changed after it connected. It does not replace the profile's primary state; the current connection remains active until the user restarts it or it reconnects with the saved changes.
_Avoid_: Disconnected, stale profile

**SSH Endpoint**:
The hostname, SSH port, and optional username stored in a **Tunnel Profile**. It identifies the SSH server independently of OpenSSH configuration.
_Avoid_: SSH Host alias, server profile, connection

**Jump Host**:
An intermediate SSH server used to reach either another Jump Host or an **SSH Endpoint**. An SSH Endpoint may resolve through multiple Jump Hosts in an ordered chain.
_Avoid_: Bastion, proxy server

**Port Forward**:
A rule with a stable identity and a case-insensitively unique name within exactly one **Tunnel Profile** that routes traffic using one of the supported forwarding modes. A Tunnel Profile may contain multiple Port Forwards, and the same Port Forward name may be reused in a different profile. Each Local Forward selects its own listen port and destination port while using the Tunnel Profile's shared hosts.
_Avoid_: Port, mapping

**Local Forward**:
A **Port Forward** that listens on the user's machine and sends traffic to a destination reachable from the SSH server. Corresponds to SSH `-L`.

**Remote Forward**:
A **Port Forward** that listens on the SSH server side and sends traffic toward a destination reachable from the user's machine. Corresponds to SSH `-R`.

**Dynamic Forward**:
A **Port Forward** that exposes a SOCKS proxy on the user's machine and selects destinations per client request. Corresponds to SSH `-D`.
_Avoid_: SOCKS tunnel

## Example dialogue

> **User:** Start my production Tunnel Profile.
>
> **Support:** That connects to the profile's SSH Endpoint, then starts the Local Forward for PostgreSQL, Remote Forward for webhooks, and Dynamic Forward for SOCKS together.
>
> **User:** Which profiles return after I log in again?
>
> **Support:** Only Auto-start Profiles; quitting EZ Tunnel stops every running profile.
>
> **User:** Wi-Fi dropped, so is the profile still active?
>
> **Support:** Yes. The Active Profile reconnects automatically until you stop it or quit EZ Tunnel.
>
> **User:** Why did my Auto-start Profile not connect?
>
> **Support:** It Needs Attention because its SSH credential requires interaction; starting it manually will show the system prompt.
>
> **User:** One local port was already occupied. Did the other forwards remain open?
>
> **Support:** No. The profile starts all-or-nothing and identifies the Port Forward that prevented it from becoming Connected.
>
> **User:** The profile says Configuration Changed. Is its tunnel down?
>
> **Support:** No. Its current connection stays active until you restart it or it reconnects using the updated Tunnel Profile.
>
> **User:** Will it keep retrying this invalid port configuration?
>
> **Support:** No. It Needs Attention until you correct it; only temporary failures enter Reconnecting automatically.
