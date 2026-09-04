import SwiftUI
import UniformTypeIdentifiers
import EZTunnelAppSupport
import EZTunnelCore

struct ManagementView: View {
    @ObservedObject var model: ApplicationModel
    let windowPresenter: ManagementWindowPresenter
    @State private var draft = TunnelProfileDraft()
    @State private var selectedProfileID: UUID?
    @State private var isChoosingPrivateKey = false

    var body: some View {
        NavigationSplitView {
            List(model.profiles, selection: $selectedProfileID) { profile in
                VStack(alignment: .leading) {
                    Text(profile.displayName.rawValue).font(.headline)
                    Text(model.state(of: profile.id).displayName)
                        .foregroundStyle(.secondary)
                    Text(
                        "\(profile.portForwards.count) "
                            + (profile.portForwards.count == 1
                                ? "Port Forward" : "Port Forwards")
                    )
                        .foregroundStyle(.secondary)
                }
                .tag(profile.id)
            }
            .navigationTitle("Tunnel Profiles")
            .toolbar {
                ToolbarItem {
                    Button("New Profile", systemImage: "plus") {
                        selectedProfileID = nil
                        draft = TunnelProfileDraft()
                        model.errorMessage = nil
                    }
                }
            }
        } detail: {
            Form {
                Section("Tunnel Profile") {
                    TextField("Profile name", text: $draft.displayName)
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
                    TextField(
                        "Destination host (optional)",
                        text: $draft.destinationHost,
                        prompt: Text("127.0.0.1")
                    )
                }

                Section("Local Forwards") {
                    ForEach($draft.localForwards) { $localForward in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: $localForward.name)
                            TextField("Listen port", text: $localForward.listenPort)
                            TextField("Destination port", text: $localForward.destinationPort)
                            if portForwardCount > 1 {
                                Button("Remove Local Forward", role: .destructive) {
                                    draft.removeLocalForward(id: localForward.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Add Local Forward", systemImage: "plus") {
                        draft.addLocalForward()
                    }
                }

                Section("Remote Forwards") {
                    ForEach($draft.remoteForwards) { $remoteForward in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: $remoteForward.name)
                            Picker("Remote listen address", selection: $remoteForward.listenAddress) {
                                Text("127.0.0.1").tag("127.0.0.1")
                                Text("::1").tag("::1")
                            }
                            TextField("Remote listen port", text: $remoteForward.listenPort)
                            TextField("Destination host", text: $remoteForward.destinationHost)
                            TextField("Destination port", text: $remoteForward.destinationPort)
                            if portForwardCount > 1 {
                                Button("Remove Remote Forward", role: .destructive) {
                                    draft.removeRemoteForward(id: remoteForward.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Add Remote Forward", systemImage: "plus") {
                        draft.addRemoteForward()
                    }
                }

                Section("Dynamic Forwards") {
                    ForEach($draft.dynamicForwards) { $dynamicForward in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: $dynamicForward.name)
                            Picker("Local listen address", selection: $dynamicForward.listenAddress) {
                                Text("127.0.0.1").tag("127.0.0.1")
                                Text("::1").tag("::1")
                            }
                            TextField("Listen port", text: $dynamicForward.listenPort)
                            if portForwardCount > 1 {
                                Button("Remove Dynamic Forward", role: .destructive) {
                                    draft.removeDynamicForward(id: dynamicForward.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Add Dynamic Forward", systemImage: "plus") {
                        draft.addDynamicForward()
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button("Save Tunnel Profile") {
                    do {
                        let profile = try draft.makeProfile()
                        if model.save(profile, credential: draft.credential) {
                            selectedProfileID = profile.id
                            draft = TunnelProfileDraft(profile: profile)
                        }
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)

                if let selectedProfileID {
                    Button("\(model.actionTitle(profileID: selectedProfileID)) Tunnel Profile") {
                        model.toggle(profileID: selectedProfileID)
                    }
                    .disabled(!model.canToggle(profileID: selectedProfileID))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedProfileID == nil ? "New Tunnel Profile" : "Edit Tunnel Profile")
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
        .onChange(of: selectedProfileID) { profileID in
            guard let selectedDraft = TunnelProfileSelection.draft(
                selecting: profileID,
                from: model.profiles
            ) else {
                return
            }
            draft = selectedDraft
            model.errorMessage = nil
        }
        .onAppear {
            if selectedProfileID == nil, let firstProfile = model.profiles.first {
                selectedProfileID = firstProfile.id
                draft = TunnelProfileDraft(profile: firstProfile)
            }
            windowPresenter.present {}
        }
        .onDisappear {
            model.managementWindowDidClose()
        }
    }

    private var portForwardCount: Int {
        draft.localForwards.count + draft.remoteForwards.count + draft.dynamicForwards.count
    }

}
