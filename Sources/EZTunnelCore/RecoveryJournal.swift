import Foundation

/// Operational intent, deliberately separate from Tunnel Profile definitions.
@MainActor
public final class RecoveryJournal {
    private struct Document: Codable {
        var activeProfileIDs = Set<UUID>()
        var processes = [UUID: RecoveryProcess]()
    }

    private let persistence: any ProfilePersistence
    private var document: Document
    public var activeProfileIDs: Set<UUID> { document.activeProfileIDs }
    var processes: [UUID: RecoveryProcess] { document.processes }

    public init(persistence: any ProfilePersistence) throws {
        self.persistence = persistence
        if let data = try persistence.load() {
            document = try JSONDecoder().decode(Document.self, from: data)
        } else {
            document = Document()
        }
    }

    func setActive(_ profileID: UUID) throws {
        var updated = document
        updated.activeProfileIDs.insert(profileID)
        try save(updated)
    }

    func record(_ process: RecoveryProcess, for profileID: UUID) throws {
        var updated = document
        updated.processes[profileID] = process
        try save(updated)
    }

    func removeProcess(for profileID: UUID) throws {
        var updated = document
        updated.processes[profileID] = nil
        try save(updated)
    }

    func stop(_ profileID: UUID) throws {
        var updated = document
        updated.activeProfileIDs.remove(profileID)
        updated.processes[profileID] = nil
        try save(updated)
    }

    func clear() throws { try save(Document()) }

    private func save(_ updated: Document) throws {
        try persistence.save(JSONEncoder().encode(updated))
        document = updated
    }
}

struct RecoveryProcess: Codable, Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let controlPath: String
}

enum RecoveryError: Error, LocalizedError {
    case previousProcessStillRunning
    case inspectionUnavailable

    var errorDescription: String? {
        switch self {
        case .previousProcessStillRunning:
            "The previous SSH process could not be safely stopped. Stop it before restarting this Tunnel Profile."
        case .inspectionUnavailable:
            "The previous SSH process could not be verified. Try stopping this Tunnel Profile again."
        }
    }
}
