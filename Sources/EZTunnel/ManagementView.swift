import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EZTunnelCore

struct ManagementView: View {
    @ObservedObject var model: ApplicationModel
    @State private var draft = ProfileDraft()
    @State private var isChoosingPrivateKey = false

    var body: some View {
        NavigationSplitView {
            List(model.profiles) { profile in
                VStack(alignment: .leading) {
                    Text(profile.displayName.rawValue).font(.headline)
                    Text(
                        "\(profile.localForwards.count) "
                            + (profile.localForwards.count == 1 ? "port" : "ports")
                    )
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tunnel Profiles")
        } detail: {
            Form {
                Section("Tunnel Profile") {
                    TextField("SSH hostname", text: $draft.sshHostname)
                    TextField("SSH port", text: $draft.sshPort)
                    TextField("Username (optional)", text: $draft.sshUsername)
                    Picker("Authentication", selection: $draft.authenticationMethod) {
                        ForEach(SSHAuthenticationMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    if draft.authenticationMethod == .privateKey {
                        TextField("Private key file", text: $draft.privateKeyPath)
                        Button("Choose Private Key…") {
                            isChoosingPrivateKey = true
                        }
                        SecureField("Private key passphrase (optional)", text: $draft.credential)
                    }
                    if draft.authenticationMethod == .password {
                        SecureField("SSH password", text: $draft.credential)
                        Text("Stored in macOS Keychain, never in profile JSON.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Local host", selection: $draft.listenAddress) {
                        Text("127.0.0.1").tag("127.0.0.1")
                        Text("::1").tag("::1")
                    }
                    TextField("Destination host", text: $draft.destinationHost)
                }

                Section("Local Forwards") {
                    ForEach($draft.localForwards) { $localForward in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: $localForward.name)
                            TextField("Listen port", text: $localForward.listenPort)
                            TextField("Destination port", text: $localForward.destinationPort)
                            if draft.localForwards.count > 1 {
                                Button("Remove Port", role: .destructive) {
                                    draft.removeLocalForward(id: localForward.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Add Port", systemImage: "plus") {
                        draft.addLocalForward()
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button("Save Tunnel Profile") {
                    do {
                        if model.save(try draft.makeProfile(), credential: draft.credential) {
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
        .fileImporter(
            isPresented: $isChoosingPrivateKey,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                draft.privateKeyPath = url.path
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows
                    .first(where: { $0.title == "EZ Tunnel" })?
                    .makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct ProfileDraft {
    private let profileID = UUID()
    var sshHostname = ""
    var sshPort = "22"
    var sshUsername = ""
    var authenticationMethod = SSHAuthenticationMethod.systemDefault
    var privateKeyPath = ""
    var credential = ""
    var listenAddress = "127.0.0.1"
    var destinationHost = ""
    var localForwards = [LocalForwardDraft()]

    mutating func addLocalForward() {
        localForwards.append(LocalForwardDraft())
    }

    mutating func removeLocalForward(id: UUID) {
        localForwards.removeAll { $0.id == id }
    }

    func makeProfile() throws -> TunnelProfile {
        guard let sshPort = Int(sshPort) else {
            throw ProfileValidationError.invalidPort(field: "SSH port", value: 0)
        }
        let forwards = try localForwards.map { try $0.makeLocalForward() }
        return try TunnelProfile(
            id: profileID,
            sshHostname: sshHostname,
            sshPort: sshPort,
            sshUsername: sshUsername,
            authenticationMethod: authenticationMethod,
            privateKeyPath: privateKeyPath,
            listenAddress: listenAddress,
            destinationHost: destinationHost,
            localForwards: forwards
        )
    }
}

private struct LocalForwardDraft: Identifiable {
    let id = UUID()
    var name = ""
    var listenPort = ""
    var destinationPort = ""

    func makeLocalForward() throws -> LocalForward {
        guard let listenPort = Int(listenPort), let destinationPort = Int(destinationPort) else {
            throw ProfileValidationError.invalidPort(field: "Port", value: 0)
        }
        return try LocalForward(
            id: id,
            name: name,
            listenPort: listenPort,
            destinationPort: destinationPort
        )
    }
}
