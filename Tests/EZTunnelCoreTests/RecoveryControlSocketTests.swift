import Darwin
import Foundation
import Testing
@testable import EZTunnelCore

@MainActor
struct RecoveryControlSocketTests {
    @Test
    func verifiedSSHMasterClosesButMismatchedSocketPeerIsUntouched() throws {
        let fixture = try SSHMasterFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.startMaster()
        let second = try fixture.startMaster()
        let os = SystemRecoveryProcessOperatingSystem()
        let firstIdentity = try #require(os.identity(pid: first.process.processIdentifier))
        let record = RecoveryProcess(
            pid: first.process.processIdentifier,
            startSeconds: firstIdentity.startSeconds,
            startMicroseconds: firstIdentity.startMicroseconds,
            controlPath: first.controlPath)
        #expect(firstIdentity.matches(record))

        let wrongPeer = RecoveryProcess(
            pid: record.pid, startSeconds: record.startSeconds,
            startMicroseconds: record.startMicroseconds, controlPath: second.controlPath)
        #expect(!os.closeTunnel(wrongPeer))
        #expect(first.process.isRunning)
        #expect(second.process.isRunning)

        try #require(os.closeTunnel(record))
        first.process.waitUntilExit()
        #expect(!first.process.isRunning)
        #expect(second.process.isRunning)
    }
}

/// All keys, listeners, SSH clients and the server belong solely to this test.
@MainActor
private final class SSHMasterFixture {
    struct Master {
        let process: Process
        let controlPath: String
    }

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var children = [Process]()
    private var controlPaths = [String]()
    private var port: UInt16 = 0

    init() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent("key").path])
            try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent("host").path])
            port = try unusedLoopbackPort()
            let configuration = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(directory.appendingPathComponent("host").path)
                AuthorizedKeysFile \(directory.appendingPathComponent("key.pub").path)
                PidFile \(directory.appendingPathComponent("sshd.pid").path)
                StrictModes no
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                UsePAM no
                """
            let configURL = directory.appendingPathComponent("sshd_config")
            try configuration.write(to: configURL, atomically: true, encoding: .utf8)
            _ = try spawn("/usr/sbin/sshd", ["-D", "-e", "-f", configURL.path])
            // Retry connection startup below instead of assuming sshd is ready.
        } catch {
            cleanUp()
            throw error
        }
    }

    func startMaster() throws -> Master {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let path = "/tmp/ez-tunnel-\(getuid())-\(UUID().uuidString)"
            controlPaths.append(path)
            let process = try spawn("/usr/bin/ssh", [
                "-M", "-S", path, "-N", "-F", "/dev/null",
                "-i", directory.appendingPathComponent("key").path,
                "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ControlPersist=no", "-p", String(port), "--", "\(NSUserName())@127.0.0.1",
            ])
            while process.isRunning && Date() < deadline {
                if FileManager.default.fileExists(atPath: path) {
                    return Master(process: process, controlPath: path)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        throw FixtureError.masterDidNotStart
    }

    func cleanUp() {
        for child in children.reversed() where child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        for path in controlPaths { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = try spawn(executable, arguments)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.commandFailed }
    }

    private func spawn(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        children.append(process)
        return process
    }

    private func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixtureError.commandFailed }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard bind(descriptor, pointer, length) == 0 else { return Int32(-1) }
                return getsockname(descriptor, pointer, &length)
            }
        }
        guard result == 0 else { throw FixtureError.commandFailed }
        return UInt16(bigEndian: address.sin_port)
    }

    private enum FixtureError: Error {
        case commandFailed
        case masterDidNotStart
    }
}
