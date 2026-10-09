import AppKit
import EZTunnelCore
import Network

/// Bridges platform events into the same application seam used by acceptance tests.
@MainActor
final class MacOSRecoveryEvents {
    private let application: EZTunnelApplication
    private var monitor: NWPathMonitor?
    private var monitorID = UUID()
    private var observers = [NSObjectProtocol]()
    private let queue = DispatchQueue(label: "EZTunnel.network-availability")

    init(application: EZTunnelApplication) {
        self.application = application
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.monitor?.cancel()
                self?.monitorID = UUID()
                self?.application.systemWillSleep()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.application.systemDidWake()
                self?.startNetworkMonitor()
            }
        })
        application.networkAvailabilityChanged(false)
        startNetworkMonitor()
    }

    private func startNetworkMonitor() {
        monitor?.cancel()
        let id = UUID()
        monitorID = id
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.monitorID == id else { return }
                self.application.networkAvailabilityChanged(available)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitorID = UUID()
        monitor?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
