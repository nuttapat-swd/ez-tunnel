import AppKit
import SwiftUI
import EZTunnelCore

struct ManagementView: View {
    @ObservedObject var model: ApplicationModel
    @State private var draft = ProfileDraft()

    var body: some View {
        NavigationSplitView {
            List(model.profiles) { profile in
                VStack(alignment: .leading) {
                    Text(profile.displayName.rawValue).font(.headline)
                    Text(profile.sshHostAlias.rawValue).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tunnel Profiles")
        } detail: {
            Form {
                Section("Tunnel Profile") {
                    TextField("SSH Host alias", text: $draft.sshHostAlias)
                    Text("This is also the Tunnel Profile name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    do {
                        if model.save(try draft.makeProfile()) {
                            draft = ProfileDraft()
                        }
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .formStyle(.grouped)
            .navigationTitle("New Tunnel Profile")
            .padding()
        }
        .onAppear {
            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.windows
                    .first(where: { $0.title == "EZ Tunnel" })
                window?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct ProfileDraft {
    private let profileID = UUID()
    private let forwardID = UUID()
    var sshHostAlias = ""
    var forwardName = ""
    var listenAddress = "127.0.0.1"
    var listenPort = ""
    var destinationHost = ""
    var destinationPort = ""

    func makeProfile() throws -> TunnelProfile {
        guard let listenPort = Int(listenPort), let destinationPort = Int(destinationPort) else {
            throw ProfileValidationError.invalidPort(field: "Port", value: 0)
        }
        return try TunnelProfile(
            id: profileID,
            sshHostAlias: sshHostAlias,
            localForward: try LocalForward(
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
