import SwiftUI
import EZTunnelCore

@main
struct EZTunnelApp: App {
    @StateObject private var model = ApplicationModel.makeDefault()

    var body: some Scene {
        MenuBarExtra("EZ Tunnel", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("EZ Tunnel", id: "management") {
            ManagementView(model: model)
                .frame(minWidth: 680, minHeight: 440)
        }
    }
}

@MainActor
private final class ApplicationModel: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile]
    @Published var errorMessage: String?

    private let application: EZTunnelApplication

    init(application: EZTunnelApplication) {
        self.application = application
        self.profiles = application.profiles
    }

    static func makeDefault() -> ApplicationModel {
        do {
            return ApplicationModel(
                application: try EZTunnelApplication(
                    persistence: FileProfilePersistence.applicationSupport()
                )
            )
        } catch {
            let fallback = try! EZTunnelApplication(persistence: UnavailablePersistence())
            let model = ApplicationModel(application: fallback)
            model.errorMessage = error.localizedDescription
            return model
        }
    }

    func configureWindowOpener(_ action: @escaping @MainActor () -> Void) {
        application.setManagementWindowOpener(ClosureWindowOpener(action: action))
    }

    func openManagementWindow() {
        application.perform(.openManagementWindow)
    }

    func save(_ profile: TunnelProfile) -> Bool {
        do {
            try application.save(profile)
            profiles = application.profiles
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
private struct ClosureWindowOpener: ManagementWindowOpening {
    let action: @MainActor () -> Void
    func openManagementWindow() { action() }
}

private struct UnavailablePersistence: ProfilePersistence {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw CocoaError(.fileWriteUnknown) }
}

private struct MenuContent: View {
    @ObservedObject var model: ApplicationModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Management Window") {
            model.openManagementWindow()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit EZ Tunnel") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            model.configureWindowOpener { openWindow(id: "management") }
        }
    }
}

private struct ManagementView: View {
    @ObservedObject var model: ApplicationModel
    @State private var draft = ProfileDraft()

    var body: some View {
        NavigationSplitView {
            List(model.profiles) { profile in
                VStack(alignment: .leading) {
                    Text(profile.displayName).font(.headline)
                    Text(profile.sshHostAlias).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tunnel Profiles")
        } detail: {
            Form {
                Section("Tunnel Profile") {
                    TextField("Display name", text: $draft.displayName)
                    TextField("SSH Host alias", text: $draft.sshHostAlias)
                }
                Section("Local Forward") {
                    TextField("Name", text: $draft.forwardName)
                    Picker("Listen address", selection: $draft.listenAddress) {
                        Text("127.0.0.1").tag("127.0.0.1")
                        Text("::1").tag("::1")
                    }
                    TextField("Listen port", text: $draft.listenPort)
                    TextField("Destination host", text: $draft.destinationHost)
                    TextField("Destination port", text: $draft.destinationPort)
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button("Save Tunnel Profile") {
                    guard let profile = draft.profile else {
                        model.errorMessage = "Listen port and destination port must be numbers."
                        return
                    }
                    if model.save(profile) {
                        draft = ProfileDraft()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .formStyle(.grouped)
            .navigationTitle("New Tunnel Profile")
            .padding()
        }
    }
}

private struct ProfileDraft {
    private let profileID = UUID()
    private let forwardID = UUID()
    var displayName = ""
    var sshHostAlias = ""
    var forwardName = ""
    var listenAddress = "127.0.0.1"
    var listenPort = ""
    var destinationHost = ""
    var destinationPort = ""

    var profile: TunnelProfile? {
        guard let listenPort = Int(listenPort), let destinationPort = Int(destinationPort) else {
            return nil
        }
        return TunnelProfile(
            id: profileID,
            displayName: displayName,
            sshHostAlias: sshHostAlias,
            localForward: LocalForward(
                id: forwardID,
                name: forwardName,
                listenAddress: listenAddress,
                listenPort: listenPort,
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )
        )
    }
}
