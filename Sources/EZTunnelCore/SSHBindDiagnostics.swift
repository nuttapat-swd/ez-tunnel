import Foundation

enum SSHBindDiagnostics {
    static func failingForward(
        in diagnostic: String, forwards: [SSHPortForwardDescriptor]
    ) -> SSHPortForwardDescriptor? {
        for line in diagnostic.split(separator: "\n") {
            if let forward = forwards.first(where: { forward in
                forward.mode != .remote
                    && line.contains("bind [\(forward.listenAddress)]:\(forward.listenPort):")
            }) {
                return forward
            }
            if let forward = forwards.first(where: { forward in
                forward.mode == .remote && (
                    line.contains("remote forward failure for: listen \(forward.listenAddress):\(forward.listenPort),")
                    || line.contains("remote forward failure for: listen [\(forward.listenAddress)]:\(forward.listenPort),")
                )
            }) {
                return forward
            }
        }
        // Some OpenSSH versions omit the address in the final error. Attribute
        // it only when exactly one Remote Forward uses that port.
        for line in diagnostic.split(separator: "\n") {
            let prefix = "Error: remote port forwarding failed for listen port "
            guard line.hasPrefix(prefix), let port = Int(line.dropFirst(prefix.count)) else { continue }
            let candidates = forwards.filter { $0.mode == .remote && $0.listenPort == port }
            if candidates.count == 1 { return candidates[0] }
        }
        return nil
    }

    static func message(for forward: SSHPortForwardDescriptor) -> String {
        let address = forward.listenAddress.contains(":")
            ? "[\(forward.listenAddress)]" : forward.listenAddress
        return "\(forward.mode.displayName) Forward \(forward.name) could not bind to "
            + "\(address):\(forward.listenPort)."
    }

    struct LocalOwner {
        let pid: Int32
        let name: String
    }

    static func localOwner(of forward: SSHPortForwardDescriptor) -> LocalOwner? {
        guard forward.mode != .remote else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        let address = forward.listenAddress.contains(":")
            ? "[\(forward.listenAddress)]" : forward.listenAddress
        process.arguments = [
            "-nP", "+c", "0", "-a", "-iTCP@\(address):\(forward.listenPort)",
            "-sTCP:LISTEN", "-Fpc",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "c", let pid {
                return LocalOwner(pid: pid, name: String(line.dropFirst()))
            }
        }
        return nil
    }
}
