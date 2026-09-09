import Darwin
import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct BindConflictAcceptanceTests {
    @Test(arguments: [0, 1, 2], [PortForwardMode.local, .remote, .dynamic])
    func bindFailureAtEveryPositionClosesTheWholeAttempt(
        position: Int, mode: PortForwardMode
    ) async throws {
        let reservations = try (0..<3).map { _ in try TestListener() }
        defer { reservations.forEach { $0.close() } }
        let ports = reservations.map(\.port)
        for index in 0..<3 where index != position { reservations[index].close() }
        let scheduler = BindRetryScheduler()
        let application = try EZTunnelApplication(
            persistence: BindPersistence(), processSupervisor: fixtureSupervisor(),
            retryScheduler: scheduler
        )
        defer { application.quit() }
        let forwards = try ports.enumerated().map { index, port -> PortForward in
            switch index == position ? mode : .dynamic {
            case .local:
                return try .local(name: "Forward \(index)", listenPort: port,
                                  destinationHost: "destination.invalid", destinationPort: 80)
            case .remote:
                return try .remote(name: "Forward \(index)", listenPort: port,
                                   destinationHost: "destination.invalid", destinationPort: 80)
            case .dynamic:
                return try .dynamic(name: "Forward \(index)", listenPort: port)
            }
        }
        let profile = try TunnelProfile(sshHostname: "fixture.invalid", portForwards: forwards)
        var observedStates = [TunnelLifecycleState]()
        application.stateDidChange = { _, state in observedStates.append(state) }
        try application.save(profile)
        try application.start(profileID: profile.id)
        try await waitForAttention(application, profile.id)
        guard case .needsAttention(let message) = application.state(of: profile.id) else { return }
        #expect(message.contains("Forward \(position)"))
        #expect(message.contains("127.0.0.1:\(ports[position])"))
        #expect(!observedStates.contains(.connected))
        for index in 0..<3 where index != position {
            let released = try TestListener(port: ports[index])
            released.close()
            #expect(!acceptsConnection(port: ports[index]))
        }
        #expect(acceptsConnection(port: ports[position]))
        // Free the conflicting listener and advance time: Needs Attention must
        // remain paused even though another attempt would now succeed.
        reservations[position].close()
        scheduler.advance()
        try await Task.sleep(for: .milliseconds(100))
        #expect(application.state(of: profile.id) == .needsAttention(message))
        #expect(!acceptsConnection(port: ports[position]))
    }

    @Test(arguments: [false, true])
    func conflictNamesTheActiveProfileThatOwnsTheListener(remote: Bool) async throws {
        let reservation = try TestListener()
        let port = reservation.port
        reservation.close()
        let application = try EZTunnelApplication(
            persistence: BindPersistence(), processSupervisor: fixtureSupervisor()
        )
        defer { application.quit() }
        let owner = try TunnelProfile(
            displayName: "Production", sshHostname: "fixture.invalid",
            portForwards: [remote
                ? .remote(name: "Production webhook", listenPort: port,
                          destinationHost: "destination.invalid", destinationPort: 80)
                : .dynamic(name: "Production proxy", listenPort: port)]
        )
        let contender = try TunnelProfile(
            displayName: "Staging", sshHostname: remote ? "fixture.invalid" : "other.invalid",
            portForwards: [remote
                ? .remote(name: "Web", listenPort: port,
                          destinationHost: "web.invalid", destinationPort: 80)
                : .local(name: "Web", listenPort: port,
                         destinationHost: "web.invalid", destinationPort: 80)]
        )
        try application.save(owner)
        try application.save(contender)
        try application.start(profileID: owner.id)
        try await waitForState(application, owner.id, matching: { $0 == .connected })
        try application.start(profileID: contender.id)
        try await waitForAttention(application, contender.id)
        guard case .needsAttention(let message) = application.state(of: contender.id) else { return }
        #expect(message.contains("Tunnel Profile Production"))
        #expect(message.contains("Web"))
        #expect(application.state(of: owner.id) == .connected)
        #expect(acceptsConnection(port: port))
    }

    @Test
    func occupiedLocalListenerNamesTheForwardAndExternalProcess() async throws {
        let occupied = try TestListener()
        defer { occupied.close() }
        let application = try EZTunnelApplication(
            persistence: BindPersistence(), processSupervisor: fixtureSupervisor()
        )
        defer { application.quit() }
        let profile = try TunnelProfile(
            displayName: "Conflicting profile", sshHostname: "fixture.invalid",
            portForwards: [.dynamic(name: "Browser proxy", listenPort: occupied.port)]
        )
        try application.save(profile)
        try application.start(profileID: profile.id)
        try await waitForAttention(application, profile.id)
        guard case .needsAttention(let message) = application.state(of: profile.id) else { return }
        #expect(message.contains("Browser proxy"))
        #expect(message.contains("127.0.0.1:\(occupied.port)"))
        #expect(message.contains("PID \(getpid())"))
        #expect(message.contains(ProcessInfo.processInfo.processName))
    }
}

@MainActor
private func fixtureSupervisor() -> SystemOpenSSHProcessSupervisor {
    SystemOpenSSHProcessSupervisor(askPassHelperURL: URL(fileURLWithPath: "/usr/bin/false")) { process, request in
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
            import socket, sys, time
            listeners = []
            for argument in sys.argv[1:]:
                mode, address, port_text = argument.split(',')
                port = int(port_text)
                listener = socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET)
                try:
                    listener.bind((address, port))
                    listener.listen(8)
                except OSError:
                    if mode == 'remote':
                        print(f'debug1: remote forward failure for: listen {address}:{port}, connect destination.invalid:80', file=sys.stderr, flush=True)
                        print(f'Error: remote port forwarding failed for listen port {port}', file=sys.stderr, flush=True)
                    else:
                        print(f'bind [{address}]:{port}: Address already in use', file=sys.stderr, flush=True)
                    sys.exit(255)
                listeners.append(listener)
                if mode == 'remote':
                    print(f'debug1: remote forward success for: listen {address}:{port}, connect destination.invalid:80', file=sys.stderr, flush=True)
                else:
                    print(f'debug1: Local forwarding listening on {address} port {port}.', file=sys.stderr, flush=True)
            print('debug1: Entering interactive session.', file=sys.stderr, flush=True)
            while True:
                time.sleep(1)
            """] + request.portForwards.map {
                "\($0.mode.rawValue),\($0.listenAddress),\($0.listenPort)"
            }
    }
}

@MainActor
private func waitForAttention(_ application: EZTunnelApplication, _ id: UUID) async throws {
    try await waitForState(application, id) {
        if case .needsAttention = $0 { return true }
        return false
    }
}

@MainActor
private func waitForState(
    _ application: EZTunnelApplication, _ id: UUID,
    matching predicate: (TunnelLifecycleState) -> Bool
) async throws {
    for _ in 0..<300 {
        if predicate(application.state(of: id)) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Unexpected state: \(application.state(of: id))")
}

private func acceptsConnection(port: Int) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

private final class BindPersistence: ProfilePersistence {
    private var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

@MainActor
private final class BindRetryScheduler: TunnelRetryScheduling {
    private var actions = [UUID: @MainActor @Sendable () -> Void]()
    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        actions[id] = action
        return id
    }
    func cancel(_ id: UUID) { actions[id] = nil }
    func advance() {
        let pending = actions.values
        actions.removeAll()
        for action in pending { action() }
    }
}

private final class TestListener {
    let descriptor: Int32
    let port: Int
    private var isClosed = false

    init(port: Int = 0) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        self.descriptor = descriptor
        self.port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }
    deinit { close() }
}
