import Foundation
import SwiftUI
import EZTunnelCore

@MainActor
final class ApplicationModel: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile]
    @Published var errorMessage: String?

    private let application: EZTunnelApplication

    init(application: EZTunnelApplication) {
        self.application = application
        self.profiles = application.profiles
    }

    static func makeDefault() -> ApplicationModel {
        do {
            return ApplicationModel(
                application: try EZTunnelApplication(
                    persistence: FileProfilePersistence.applicationSupport(),
                    credentialStore: KeychainSSHCredentialStore()
                )
            )
        } catch {
            let fallback = try! EZTunnelApplication(persistence: UnavailablePersistence())
            let model = ApplicationModel(application: fallback)
            model.errorMessage = error.localizedDescription
            return model
        }
    }

    func save(_ profile: TunnelProfile, credential: String?) -> Bool {
        do {
            try application.save(profile, credential: credential)
            profiles = application.profiles
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private struct UnavailablePersistence: ProfilePersistence {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw CocoaError(.fileWriteUnknown) }
}
