# Distribute outside the Mac App Store

EZ Tunnel will be signed with an Apple Developer ID, notarized, and distributed directly rather than through the Mac App Store. Direct distribution avoids App Sandbox constraints that would complicate access to the user's SSH configuration and agent, launching SSH processes, and supervising tunnels in the background; the trade-off is that the project must operate its own download, update, signing, and notarization pipeline.
