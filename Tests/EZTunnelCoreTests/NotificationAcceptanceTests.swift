import EZTunnelAppSupport
import Foundation
import Testing

@testable import EZTunnelCore

@MainActor
struct NotificationAcceptanceTests {
    @Test(arguments: [false, true])
    func firstConnectionAfterLongInitialRetriesIsNotARecovery(login: Bool) throws {
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        let scheduler = NotificationScheduler()
        var now = Date(timeIntervalSince1970: 0)
        let app = try EZTunnelApplication(
            persistence: NotificationPersistence(), processSupervisor: supervisor,
            retryScheduler: scheduler, notificationDelivery: sink, notificationTime: { now })
        let profile = try notificationProfile(autoStart: login)
        try app.save(profile)
        if login { app.launch(.loginItem) } else { try app.start(profileID: profile.id) }
        supervisor.report(.failed(.temporary("Server unavailable")), for: profile.id)
        now = now.addingTimeInterval(120)
        scheduler.fire()
        supervisor.report(.ready, for: profile.id)
        #expect(sink.notifications.count == (login ? 1 : 0))
        #expect(!sink.notifications.contains { $0.title.contains("Recovered") })
    }

    @Test
    func notificationPreferenceAppliesImmediatelyWithoutRequiringRestart() throws {
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        var now = Date(timeIntervalSince1970: 0)
        let app = try EZTunnelApplication(
            persistence: NotificationPersistence(), processSupervisor: supervisor,
            notificationDelivery: sink, notificationTime: { now })
        var profile = try notificationProfile()
        try app.save(profile)
        try app.start(profileID: profile.id)
        supervisor.report(.ready, for: profile.id)
        profile.notificationsEnabled = false
        try app.save(profile)
        #expect(!app.configurationChanged(for: profile.id))
        app.systemWillSleep()
        now = now.addingTimeInterval(90)
        app.systemDidWake()
        app.networkAvailabilityChanged(true)
        supervisor.report(.ready, for: profile.id)
        #expect(sink.notifications.isEmpty)
    }

    @Test
    func olderProfilesDefaultToEnabled() throws {
        let profile = try notificationProfile()
        let data = try JSONEncoder().encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "notificationsEnabled")
        let olderData = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(TunnelProfile.self, from: olderData).notificationsEnabled)
    }

    @Test
    func loginFailureNotifiesOnceWithoutPromptAndLaterAttentionStillNotifies() throws {
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        let scheduler = NotificationScheduler()
        let app = try EZTunnelApplication(
            persistence: NotificationPersistence(), processSupervisor: supervisor,
            retryScheduler: scheduler, notificationDelivery: sink)
        let profile = try notificationProfile(autoStart: true)
        try app.save(profile)
        app.launch(.loginItem)
        #expect(sink.permissionPrompts == [false])
        #expect(supervisor.requests.allSatisfy { !$0.allowsInteraction })
        supervisor.report(.failed(.temporary("Server unavailable")), for: profile.id)
        #expect(sink.notifications.count == 1)
        scheduler.fire()
        supervisor.report(.failed(.temporary("Server unavailable")), for: profile.id)
        #expect(sink.notifications.count == 1)
        scheduler.fire()
        supervisor.report(.failed(.needsAttention("Trust the SSH host key.")), for: profile.id)
        #expect(sink.notifications.count == 2)
        #expect(sink.notifications.last?.body.contains("Trust the SSH host key.") == true)
    }

    @Test(arguments: [30.0, 60.0, 60.001])
    func recoveryOnlyAfterMoreThanOneMinute(duration: TimeInterval) throws {
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        let scheduler = NotificationScheduler()
        var now = Date(timeIntervalSince1970: 0)
        let app = try EZTunnelApplication(
            persistence: NotificationPersistence(), processSupervisor: supervisor,
            retryScheduler: scheduler, notificationDelivery: sink, notificationTime: { now })
        let profile = try notificationProfile()
        try app.save(profile)
        try app.start(profileID: profile.id)
        supervisor.report(.ready, for: profile.id)
        supervisor.report(.failed(.temporary("Network unavailable")), for: profile.id)
        now = now.addingTimeInterval(duration / 2)
        scheduler.fire()
        supervisor.report(.failed(.temporary("Still unavailable")), for: profile.id)
        #expect(sink.notifications.isEmpty)
        now = now.addingTimeInterval(duration / 2)
        scheduler.fire()
        supervisor.report(.ready, for: profile.id)
        supervisor.report(.ready, for: profile.id)
        #expect(sink.notifications.count == (duration > 60 ? 1 : 0))
        if duration > 60 { #expect(sink.notifications.first?.title == "Production — Recovered") }
    }

    @Test
    func sleepRecoveryNotifiesButStoppingCancelsOutage() throws {
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        var now = Date(timeIntervalSince1970: 0)
        let app = try EZTunnelApplication(
            persistence: NotificationPersistence(), processSupervisor: supervisor,
            notificationDelivery: sink, notificationTime: { now })
        let profile = try notificationProfile()
        try app.save(profile)
        try app.start(profileID: profile.id)
        supervisor.report(.ready, for: profile.id)
        app.systemWillSleep()
        now = now.addingTimeInterval(61)
        app.systemDidWake()
        app.networkAvailabilityChanged(true)
        supervisor.report(.ready, for: profile.id)
        #expect(sink.notifications.count == 1)
        app.systemWillSleep()
        now = now.addingTimeInterval(120)
        app.stop(profileID: profile.id)
        app.systemDidWake()
        app.networkAvailabilityChanged(true)
        try app.start(profileID: profile.id)
        supervisor.report(.ready, for: profile.id)
        #expect(sink.notifications.count == 1)
    }

    @Test
    func disabledSettingSurvivesEditingAndRelaunchAndSuppressesOnlyThatProfile() throws {
        let persistence = NotificationPersistence()
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        let app = try EZTunnelApplication(persistence: persistence)
        var disabled = try notificationProfile(autoStart: true)
        var draft = TunnelProfileDraft(profile: disabled)
        draft.notificationsEnabled = false
        disabled = try draft.makeProfile()
        try app.save(disabled)
        var enabled = try notificationProfile(autoStart: true)
        enabled.displayName = try TunnelProfileName(rawValue: "Staging")
        try app.save(enabled)
        let relaunched = try EZTunnelApplication(
            persistence: persistence, processSupervisor: supervisor,
            notificationDelivery: sink)
        #expect(relaunched.profiles.first?.notificationsEnabled == false)
        #expect(TunnelProfileDraft(profile: relaunched.profiles[0]).notificationsEnabled == false)
        relaunched.launch(.loginItem)
        supervisor.report(.failed(.needsAttention("Manual start required")), for: disabled.id)
        supervisor.report(.failed(.needsAttention("Manual start required")), for: enabled.id)
        #expect(sink.notifications.map(\.profileID) == [enabled.id])
    }

    @Test
    func attentionIdentifiesProfileAndActionWithoutDuplicates() throws {
        let sink = RecordingNotifications()
        let supervisor = NotificationSupervisor()
        let app = try EZTunnelApplication(
            persistence: NotificationPersistence(), processSupervisor: supervisor,
            notificationDelivery: sink)
        let profile = try notificationProfile()
        try app.save(profile)
        try app.start(profileID: profile.id)
        supervisor.report(.failed(.needsAttention("Trust the SSH host key.")), for: profile.id)
        supervisor.report(.failed(.needsAttention("Trust the SSH host key.")), for: profile.id)
        #expect(sink.notifications.count == 1)
        #expect(sink.notifications.first?.title.contains("Production") == true)
        #expect(sink.notifications.first?.body.contains("Trust the SSH host key.") == true)
    }
}

private func notificationProfile(autoStart: Bool = false) throws -> TunnelProfile {
    try TunnelProfile(
        displayName: "Production", sshHostname: "ssh.example.com", autoStart: autoStart,
        localForwards: [LocalForward(name: "Web", listenPort: 8080, destinationPort: 80)])
}
private final class NotificationPersistence: ProfilePersistence {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
@MainActor
private final class RecordingNotifications: TunnelNotificationDelivering {
    var notifications = [TunnelNotification]()
    var permissionPrompts = [Bool]()
    func prepare(allowPermissionPrompt: Bool) { permissionPrompts.append(allowPermissionPrompt) }
    func deliver(_ notification: TunnelNotification) { notifications.append(notification) }
}
@MainActor
private final class NotificationScheduler: TunnelRetryScheduling {
    var action: (@MainActor @Sendable () -> Void)?
    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void)
        -> UUID
    {
        self.action = action
        return UUID()
    }
    func cancel(_ id: UUID) { action = nil }
    func fire() {
        let next = action
        action = nil
        next?()
    }
}
@MainActor
private final class NotificationSupervisor: SSHProcessSupervising {
    var requests = [SSHProcessRequest]()
    var handlers = [UUID: @MainActor @Sendable (SSHProcessEvent) -> Void]()
    func start(
        _ request: SSHProcessRequest,
        eventHandler: @escaping @MainActor @Sendable (SSHProcessEvent) -> Void
    ) throws {
        requests.append(request)
        handlers[request.profileID] = eventHandler
    }
    func stop(profileID: UUID) {}
    func report(_ event: SSHProcessEvent, for id: UUID) { handlers[id]?(event) }
}
