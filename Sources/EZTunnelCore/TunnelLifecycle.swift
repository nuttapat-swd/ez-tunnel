import Foundation
import Darwin

public enum TunnelLifecycleState: Equatable, Sendable {
    case stopped
    case connecting
    case connected
    case reconnecting
    case needsAttention(String)
    case stopping

    public var displayName: String {
        switch self {
        case .stopped: "Stopped"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .needsAttention: "Needs Attention"
        case .stopping: "Stopping"
        }
    }
}

public enum TunnelLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case profileNotFound(UUID)
    case profileAlreadyActive(UUID)
    case testConnectionAlreadyInProgress(UUID)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            "Tunnel Profile \(id.uuidString) was not found."
        case .profileAlreadyActive:
            "The Tunnel Profile is already active."
        case .testConnectionAlreadyInProgress:
            "A Test Connection is already in progress for this Tunnel Profile."
        }
    }
}

public struct SSHProcessRequest: Sendable {
    public let profileID: UUID
    public let executableURL: URL
    public let arguments: [String]
    let portForwards: [SSHPortForwardDescriptor]
    let credential: String?
    let allowsInteraction: Bool
    let endpoint: String
    let credentialKind: SSHCredentialKind?

    init(
        profile: TunnelProfile,
        allowsInteraction: Bool,
        includesPortForwards: Bool = true,
        credential: String? = nil
    ) {
        self.profileID = profile.id
        self.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        self.credential = credential
        self.allowsInteraction = allowsInteraction
        self.endpoint = "\(profile.sshHostname.rawValue):\(profile.sshPort.rawValue)"
        switch profile.authenticationMethod {
        case .systemDefault: self.credentialKind = nil
        case .password: self.credentialKind = .password
        case .privateKey: self.credentialKind = .privateKeyPassphrase
        }
        let requestedPortForwards = includesPortForwards ? profile.portForwards : []
        self.portForwards = requestedPortForwards.map {
            SSHPortForwardDescriptor(
                id: $0.id,
                name: $0.name.rawValue,
                mode: $0.mode,
                listenAddress: $0.listenAddress.rawValue,
                listenPort: $0.listenPort.rawValue
            )
        }
        var arguments = [
            "-v",
            "-N",
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=\(allowsInteraction ? "ask" : "yes")",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-p", String(profile.sshPort.rawValue),
        ]
        if !allowsInteraction {
            arguments += ["-o", "BatchMode=yes"]
        }
        if credential != nil {
            arguments += ["-o", "NumberOfPasswordPrompts=1"]
        }
        if let username = profile.sshUsername?.rawValue {
            arguments += ["-l", username]
        }
        if profile.authenticationMethod == .privateKey, let path = profile.privateKeyPath {
            arguments += ["-o", "IdentitiesOnly=yes", "-i", path]
        }
        for forward in requestedPortForwards {
            let listenAddress = Self.forwardingHost(forward.listenAddress.rawValue)
            switch forward {
            case .localForward(let local, _, let destinationHost):
                arguments += [
                    "-L",
                    "\(listenAddress):\(local.listenPort.rawValue):"
                        + "\(Self.forwardingHost(destinationHost.rawValue)):"
                        + "\(local.destinationPort.rawValue)",
                ]
            case .remoteForward(let remote):
                arguments += [
                    "-R",
                    "\(listenAddress):\(remote.listenPort.rawValue):"
                        + "\(Self.forwardingHost(remote.destinationHost.rawValue)):"
                        + "\(remote.destinationPort.rawValue)",
                ]
            case .dynamicForward(let dynamic):
                arguments += [
                    "-D",
                    "\(listenAddress):\(dynamic.listenPort.rawValue)",
                ]
            }
        }
        arguments += ["--", profile.sshHostname.rawValue]
        self.arguments = arguments
    }

    private static func forwardingHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}

struct SSHPortForwardDescriptor: Equatable, Sendable {
    let id: UUID
    let name: String
    let mode: PortForwardMode
    let listenAddress: String
    let listenPort: Int
}

struct SSHProcessReadinessTracker: Sendable {
    private let portForwards: [SSHPortForwardDescriptor]
    private var readyPortForwardIDs = Set<UUID>()
    private var sessionEstablished = false

    init(portForwards: [SSHPortForwardDescriptor]) {
        self.portForwards = portForwards
    }

    mutating func receive(_ diagnostic: String) -> Bool {
        if diagnostic.contains("Entering interactive session") {
            sessionEstablished = true
        }
        for portForward in portForwards where isReady(portForward, in: diagnostic) {
            readyPortForwardIDs.insert(portForward.id)
        }
        return sessionEstablished && readyPortForwardIDs.count == portForwards.count
    }

    private func isReady(
        _ portForward: SSHPortForwardDescriptor,
        in diagnostic: String
    ) -> Bool {
        switch portForward.mode {
        case .local, .dynamic:
            diagnostic.contains(
                "Local forwarding listening on \(portForward.listenAddress) "
                    + "port \(portForward.listenPort)"
            )
        case .remote:
            diagnostic.contains(
                "remote forward success for: listen \(portForward.listenAddress):"
                    + "\(portForward.listenPort)"
            ) || diagnostic.contains(
                "remote forward success for: listen [\(portForward.listenAddress)]:"
                    + "\(portForward.listenPort)"
            )
        }
    }
}

public enum SSHProcessFailure: Equatable, Sendable {
    case temporary(String)
    case needsAttention(String)
}

public enum SSHProcessEvent: Equatable, Sendable {
    case ready
    case failed(SSHProcessFailure)
}

@MainActor
public protocol TunnelRetryScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> UUID
    func cancel(_ id: UUID)
}

@MainActor
public final class SystemTunnelRetryScheduler: TunnelRetryScheduling {
    private var tasks = [UUID: Task<Void, Never>]()

    public init() {}

    public func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tasks[id] = nil
            action()
        }
        return id
    }

    public func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }
}

@MainActor
public protocol SSHProcessSupervising: AnyObject {
    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws
    func stop(profileID: UUID)
}

@MainActor
public final class SystemOpenSSHProcessSupervisor: SSHProcessSupervising {
    private static let interventionMarkers = [
        "Address already in use",
        "Could not request local forwarding",
        "Host key verification failed",
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
        "Permission denied",
        "Could not resolve hostname",
        "no such identity",
        "Bad configuration option",
    ]

    private final class OwnedProcess {
        let process: Process
        let standardError: Pipe
        let request: SSHProcessRequest
        var readinessTracker: SSHProcessReadinessTracker
        var diagnosticOutput = ""
        var readyReported = false
        var askPassResources: AskPassResources?

        init(process: Process, standardError: Pipe, request: SSHProcessRequest) {
            self.process = process
            self.standardError = standardError
            self.request = request
            self.readinessTracker = SSHProcessReadinessTracker(
                portForwards: request.portForwards
            )
        }
    }

    private var processes = [UUID: OwnedProcess]()

    public init() {}

    public func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        let ownedProcess = OwnedProcess(
            process: process,
            standardError: standardError,
            request: request
        )
        var environment = ProcessInfo.processInfo.environment
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_PROMPT", "EZ_TUNNEL_SSH_CREDENTIAL_PIPE",
                    "EZ_TUNNEL_SSH_CREDENTIAL_KIND", "EZ_TUNNEL_SSH_ENDPOINT"] {
            environment[key] = nil
        }
        environment["LC_ALL"] = "C"
        environment["SSH_ASKPASS_REQUIRE"] = request.allowsInteraction ? "force" : "never"
        if request.allowsInteraction {
            let helperURL = Bundle.main.executableURL!.deletingLastPathComponent()
                .appendingPathComponent("EZTunnelAskPass")
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw SSHInteractionError.helperUnavailable
            }
            environment["SSH_ASKPASS"] = helperURL.path
            environment["EZ_TUNNEL_SSH_ENDPOINT"] = request.endpoint
            environment["EZ_TUNNEL_SSH_CREDENTIAL_KIND"] = request.credentialKind?.rawValue
            if let credential = request.credential {
                let resources = try makeAskPassResources(credential: credential)
                environment["EZ_TUNNEL_SSH_CREDENTIAL_PIPE"] = resources.pipeURL.path
                ownedProcess.askPassResources = resources
            }
        }
        process.environment = environment

        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let output = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.receive(output, for: request.profileID, eventHandler: eventHandler)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                self?.processDidTerminate(
                    profileID: request.profileID,
                    status: status,
                    eventHandler: eventHandler
                )
            }
        }

        processes[request.profileID] = ownedProcess
        do {
            try process.run()
        } catch {
            processes[request.profileID] = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            removeAskPassResources(ownedProcess.askPassResources)
            throw error
        }
    }

    public func stop(profileID: UUID) {
        guard let ownedProcess = processes.removeValue(forKey: profileID) else { return }
        ownedProcess.standardError.fileHandleForReading.readabilityHandler = nil
        ownedProcess.process.terminationHandler = nil
        if ownedProcess.process.isRunning {
            // OpenSSH may be suspended while trying to read from a controlling
            // terminal. Resume only this owned process so SIGTERM can be handled.
            _ = Darwin.kill(ownedProcess.process.processIdentifier, SIGCONT)
            ownedProcess.process.terminate()
            ownedProcess.process.waitUntilExit()
        }
        removeAskPassResources(ownedProcess.askPassResources)
    }

    private func receive(
        _ output: String,
        for profileID: UUID,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) {
        guard let ownedProcess = processes[profileID] else { return }
        ownedProcess.diagnosticOutput += output
        if ownedProcess.diagnosticOutput.count > 16_384 {
            ownedProcess.diagnosticOutput.removeFirst(
                ownedProcess.diagnosticOutput.count - 16_384
            )
        }
        if !ownedProcess.readyReported,
           ownedProcess.readinessTracker.receive(ownedProcess.diagnosticOutput) {
            ownedProcess.readyReported = true
            eventHandler(.ready)
        }
    }

    private func processDidTerminate(
        profileID: UUID,
        status: Int32,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) {
        guard let ownedProcess = processes.removeValue(forKey: profileID) else { return }
        ownedProcess.standardError.fileHandleForReading.readabilityHandler = nil
        removeAskPassResources(ownedProcess.askPassResources)
        let diagnostic = ownedProcess.diagnosticOutput
        eventHandler(.failed(Self.interpretFailure(
            diagnostic: diagnostic,
            status: status,
            portForwards: ownedProcess.request.portForwards
        )))
    }

    private struct AskPassResources {
        let directoryURL: URL
        let pipeURL: URL
        let pipeHandle: FileHandle
    }

    private func makeAskPassResources(credential: String) throws -> AskPassResources {
        // OpenSSH askpass reads at most 1023 bytes and ends at the first newline.
        guard !credential.isEmpty, credential.utf8.count < 1024,
              !credential.contains("\n"), !credential.contains("\r"),
              !credential.contains("\0") else { throw SSHInteractionError.invalidCredential }
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ez-tunnel-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let pipeURL = directoryURL.appendingPathComponent("credential")
        guard mkfifo(pipeURL.path, S_IRUSR | S_IWUSR) == 0 else {
            try? FileManager.default.removeItem(at: directoryURL)
            throw SSHInteractionError.credentialUnavailable
        }
        let descriptor = open(pipeURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directoryURL)
            throw SSHInteractionError.credentialUnavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(credential.utf8))
            return AskPassResources(
                directoryURL: directoryURL,
                pipeURL: pipeURL,
                pipeHandle: handle
            )
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: directoryURL)
            throw SSHInteractionError.credentialUnavailable
        }
    }

    private func removeAskPassResources(_ resources: AskPassResources?) {
        guard let resources else { return }
        try? resources.pipeHandle.close()
        try? FileManager.default.removeItem(at: resources.directoryURL)
    }

    static func interpretFailure(
        diagnostic: String,
        status: Int32,
        portForwards: [SSHPortForwardDescriptor]
    ) -> SSHProcessFailure {
        let message = diagnosticMessage(
            from: diagnostic,
            status: status,
            portForwards: portForwards
        )
        return classifyFailure(diagnostic: diagnostic, message: message)
    }

    private static func diagnosticMessage(
        from diagnostic: String,
        status: Int32,
        portForwards: [SSHPortForwardDescriptor]
    ) -> String {
        if diagnostic.localizedCaseInsensitiveContains(
            "REMOTE HOST IDENTIFICATION HAS CHANGED"
        ) {
            return "The SSH Endpoint host key has changed. Verify it outside EZ Tunnel; "
                + "automatic replacement is disabled."
        }
        if diagnostic.localizedCaseInsensitiveContains("Host key verification failed") {
            return "The SSH Endpoint host key is not trusted. Verify its fingerprint and add "
                + "it to known_hosts before retrying."
        }
        if diagnostic.localizedCaseInsensitiveContains("Permission denied") {
            return "Authentication was rejected for the SSH Endpoint. Verify the username and "
                + "credential before retrying."
        }
        if diagnostic.localizedCaseInsensitiveContains("Could not resolve hostname") {
            return "The SSH Endpoint hostname could not be resolved. Verify the hostname and "
                + "network connection."
        }
        if diagnostic.localizedCaseInsensitiveContains("no such identity")
            || (diagnostic.localizedCaseInsensitiveContains("Identity file")
                && diagnostic.localizedCaseInsensitiveContains("not accessible")) {
            return "The selected private key file is unavailable. Choose a readable private key."
        }
        if diagnostic.localizedCaseInsensitiveContains("Address already in use"),
           let forward = portForwards.first(where: {
               diagnostic.contains("port: \($0.listenPort)")
                   || diagnostic.contains("]: \($0.listenPort)")
                   || diagnostic.contains("]:\($0.listenPort)")
           }) {
            return "\(forward.mode.displayName) Forward \(forward.name) could not bind to "
                + "\(forward.listenAddress):\(forward.listenPort)."
        }
        let lines = diagnostic.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let usefulLine = lines.last(where: { line in
            Self.interventionMarkers.contains(where: line.localizedCaseInsensitiveContains)
        }) ?? lines.last(where: { !$0.hasPrefix("debug") })
        return usefulLine ?? "OpenSSH exited with status \(status)."
    }

    private static func classifyFailure(
        diagnostic: String,
        message: String
    ) -> SSHProcessFailure {
        if diagnostic.localizedCaseInsensitiveContains("Identity file"),
           diagnostic.localizedCaseInsensitiveContains("not accessible") {
            return .needsAttention(message)
        }
        if Self.interventionMarkers.contains(
            where: diagnostic.localizedCaseInsensitiveContains
        ) {
            return .needsAttention(message)
        }
        return .temporary(message)
    }
}

private enum SSHInteractionError: LocalizedError {
    case helperUnavailable
    case invalidCredential
    case credentialUnavailable

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The SSH prompt helper is unavailable. Rebuild or reinstall EZ Tunnel."
        case .invalidCredential:
            "The SSH credential cannot be supplied to OpenSSH. Use a single line shorter than 1024 bytes."
        case .credentialUnavailable:
            "The SSH credential could not be supplied securely. Retry the manual connection."
        }
    }
}
