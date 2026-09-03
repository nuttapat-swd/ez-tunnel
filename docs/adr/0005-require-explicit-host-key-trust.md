# Require explicit SSH host-key trust

EZ Tunnel will never accept a new or changed SSH host key automatically. A manual connection may present the host, key type, and fingerprint for explicit approval, while unattended connections enter Needs Attention; a changed key is treated as a higher-severity security event and is not offered one-click replacement, trading some convenience for protection against connecting to an impersonated host.
