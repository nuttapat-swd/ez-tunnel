# Use the macOS system OpenSSH client

EZ Tunnel will create and supervise tunnel connections by running `/usr/bin/ssh` rather than embedding an SSH protocol library. This preserves compatibility with the user's OpenSSH configuration, SSH agent, Keychain integration, ProxyJump behavior, and hardware-backed keys while keeping private-key handling outside the application; in exchange, the application must translate process output into useful connection states and errors.
