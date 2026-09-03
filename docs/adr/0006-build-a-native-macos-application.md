# Build a native macOS application

EZ Tunnel will be implemented in Swift with SwiftUI, using AppKit only where native menu-bar lifecycle or process integration requires it. This fits the macOS-only scope and integrates directly with platform services such as launch-at-login, notifications, signing, and notarization; the trade-off is that supporting another desktop operating system later will require a new platform-facing application layer.
