# Delegate SSH secret handling to OpenSSH

Status: Superseded by ADR 0008.

EZ Tunnel will neither store SSH passwords nor read or store private keys; authentication remains the responsibility of OpenSSH, ssh-agent, and macOS Keychain. A manual start may invoke an interactive system prompt, while unattended starts and reconnects must not prompt and will move the profile to Needs Attention when credentials are unavailable, reducing the application's secret-handling surface at the cost of requiring users to prepare credentials outside EZ Tunnel.
