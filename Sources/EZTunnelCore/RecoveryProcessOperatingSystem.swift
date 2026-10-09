import Darwin
import Foundation

struct RecoveryProcessIdentity: Equatable {
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
    let arguments: [String]
    let userID: UInt32

    func matches(_ process: RecoveryProcess) -> Bool {
        let prefix = "/tmp/ez-tunnel-\(getuid())-"
        guard process.controlPath.hasPrefix(prefix),
            UUID(uuidString: String(process.controlPath.dropFirst(prefix.count))) != nil,
            userID == getuid(), executable == "/usr/bin/ssh",
            startSeconds == process.startSeconds, startMicroseconds == process.startMicroseconds,
            arguments.contains("-M"),
            let index = arguments.firstIndex(of: "-S"), index + 1 < arguments.count
        else { return false }
        return arguments[index + 1] == process.controlPath
    }
}

enum RecoveryProcessInspection {
    case absent
    case unavailable
    case present(RecoveryProcessIdentity)
}

@MainActor
protocol RecoveryProcessOperatingSystem {
    func inspect(pid: Int32) -> RecoveryProcessInspection
    func findProcess(controlPath: String) throws -> RecoveryProcess?
    /// Must target the verified instance, never signal a PID obtained from disk.
    func closeTunnel(_ process: RecoveryProcess) -> Bool
}

@MainActor
struct SystemRecoveryProcessOperatingSystem: RecoveryProcessOperatingSystem {
    func inspect(pid: Int32) -> RecoveryProcessInspection {
        guard pid > 0 else { return .absent }
        if let identity = identity(pid: pid) { return .present(identity) }
        if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return .absent }
        return .unavailable
    }

    func findProcess(controlPath: String) throws -> RecoveryProcess? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw CocoaError(.fileReadUnknown) }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let filled = proc_listallpids(&pids, capacity)
        guard filled > 0, filled < pids.count else { throw CocoaError(.fileReadUnknown) }
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
                if case .absent = inspect(pid: pid) { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard info.pbi_uid == getuid() else { continue }
            let current: RecoveryProcessIdentity
            switch inspect(pid: pid) {
            case .absent: continue
            case .unavailable: throw CocoaError(.fileReadUnknown)
            case .present(let identity): current = identity
            }
            let candidate = RecoveryProcess(pid: pid, startSeconds: current.startSeconds,
                                            startMicroseconds: current.startMicroseconds, controlPath: controlPath)
            if current.matches(candidate) { return candidate }
        }
        return nil
    }

    func identity(pid: Int32) -> RecoveryProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0,
            length > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &length, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        while cursor < length && bytes[cursor] != 0 { cursor += 1 }
        while cursor < length && bytes[cursor] == 0 { cursor += 1 }
        var arguments = [String]()
        for _ in 0..<argc {
            let start = cursor
            while cursor < length && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < length else { return nil }
            arguments.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        // Inspection is a snapshot; refuse it if the PID changed while reading.
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
            info.pbi_start_tvsec == after.pbi_start_tvsec,
            info.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return RecoveryProcessIdentity(
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            executable: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            arguments: arguments, userID: info.pbi_uid)
    }

    func closeTunnel(_ process: RecoveryProcess) -> Bool {
        // Speak OpenSSH's mux protocol over the already-connected socket. The
        // descriptor pins the peer even if its PID or pathname is later reused.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(process.controlPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, addressSize)
            }
        }
        guard connected == 0 else {
            if case .absent = inspect(pid: process.pid) { return true }
            return false
        }
        var peerPID: Int32 = 0
        var peerSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerSize) == 0,
            peerPID == process.pid, identity(pid: peerPID)?.matches(process) == true
        else { return false }
        guard sendPacket([Mux.hello, Mux.version], to: descriptor),
            let hello = receivePacket(from: descriptor),
            hello.starts(with: payload([Mux.hello, Mux.version])),
            sendPacket([Mux.terminate, 1], to: descriptor)
        else { return false }
        let response = receivePacket(from: descriptor)
        // OpenSSH may exit before its OK reply reaches the client. In either
        // case require the verified process instance to disappear below.
        if let response, response != payload([Mux.ok, 1]) { return false }
        let deadline = Date().addingTimeInterval(2)
        repeat {
            switch inspect(pid: process.pid) {
            case .absent: return true
            case .present(let current) where !current.matches(process): return true
            default: break
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
    }

    private func sendPacket(_ words: [UInt32], to descriptor: Int32) -> Bool {
        let packet = payload([UInt32(words.count * 4)] + words)
        return packet.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private func payload(_ words: [UInt32]) -> Data {
        words.map { $0.bigEndian }.withUnsafeBytes { Data($0) }
    }

    private func receivePacket(from descriptor: Int32) -> Data? {
        var length: UInt32 = 0
        guard recv(descriptor, &length, 4, MSG_WAITALL) == 4 else { return nil }
        let count = Int(UInt32(bigEndian: length))
        guard count >= 8, count <= 4096 else { return nil }
        var bytes = Data(count: count)
        let received = bytes.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, count, MSG_WAITALL) }
        guard received == count else { return nil }
        return bytes
    }

    private enum Mux {
        static let hello: UInt32 = 1
        static let version: UInt32 = 4
        static let terminate: UInt32 = 0x10000005
        static let ok: UInt32 = 0x80000001
    }
}
