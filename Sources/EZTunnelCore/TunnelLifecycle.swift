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

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            "Tunnel Profile \(id.uuidString) was not found."
        case .profileAlreadyActive:
            "The Tunnel Profile is already active."
        }
    }
}

public struct SSHProcessRequest: Equatable, Sendable {
    public let profileID: UUID
    public let executableURL: URL
    public let arguments: [String]
    let localForwards: [SSHLocalForwardDescriptor]

    init(profile: TunnelProfile, allowsInteraction: Bool) {
        self.profileID = profile.id
        self.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        self.localForwards = profile.localForwards.map {
            SSHLocalForwardDescriptor(
                name: $0.name.rawValue,
                listenAddress: profile.listenAddress.rawValue,
                listenPort: $0.listenPort.rawValue
            )
        }
        var arguments = [
            "-v",
            "-N",
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-p", String(profile.sshPort.rawValue),
        ]
        if !allowsInteraction {
            arguments += ["-o", "BatchMode=yes"]
        }
        if let username = profile.sshUsername?.rawValue {
            arguments += ["-l", username]
        }
        if profile.authenticationMethod == .privateKey, let path = profile.privateKeyPath {
            arguments += ["-o", "IdentitiesOnly=yes", "-i", path]
        }
        for forward in profile.localForwards {
            let listenAddress = Self.forwardingHost(profile.listenAddress.rawValue)
            let destinationHost = Self.forwardingHost(profile.destinationHost.rawValue)
            arguments += [
                "-L",
                "\(listenAddress):\(forward.listenPort.rawValue):"
                    + "\(destinationHost):\(forward.destinationPort.rawValue)",
            ]
        }
        arguments += ["--", profile.sshHostname.rawValue]
        self.arguments = arguments
    }

    private static func forwardingHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}

struct SSHLocalForwardDescriptor: Equatable, Sendable {
    let name: String
    let listenAddress: String
    let listenPort: Int
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
        var diagnosticOutput = ""
        var readyReported = false

        init(process: Process, standardError: Pipe, request: SSHProcessRequest) {
            self.process = process
            self.standardError = standardError
            self.request = request
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
           ownedProcess.diagnosticOutput.contains("Entering interactive session") {
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
        let diagnostic = ownedProcess.diagnosticOutput
        let message = diagnosticMessage(
            from: diagnostic,
            status: status,
            localForwards: ownedProcess.request.localForwards
        )
        eventHandler(.failed(classifyFailure(diagnostic: diagnostic, message: message)))
    }

    private func diagnosticMessage(
        from diagnostic: String,
        status: Int32,
        localForwards: [SSHLocalForwardDescriptor]
    ) -> String {
        if diagnostic.localizedCaseInsensitiveContains("Address already in use"),
           let forward = localForwards.first(where: {
               diagnostic.contains("port: \($0.listenPort)")
                   || diagnostic.contains("]: \($0.listenPort)")
                   || diagnostic.contains("]:\($0.listenPort)")
           }) {
            return "Local Forward \(forward.name) could not bind to "
                + "\(forward.listenAddress):\(forward.listenPort)."
        }
        let lines = diagnostic.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let usefulLine = lines.last(where: { line in
            Self.interventionMarkers.contains(where: line.localizedCaseInsensitiveContains)
        }) ?? lines.last(where: { !$0.hasPrefix("debug") })
        return usefulLine ?? "OpenSSH exited with status \(status)."
    }

    private func classifyFailure(diagnostic: String, message: String) -> SSHProcessFailure {
        if Self.interventionMarkers.contains(
            where: diagnostic.localizedCaseInsensitiveContains
        ) {
            return .needsAttention(message)
        }
        return .temporary(message)
    }
}
