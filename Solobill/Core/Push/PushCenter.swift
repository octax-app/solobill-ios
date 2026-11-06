import Observation
import SwiftUI
import UIKit
import UserNotifications

/// Where a tapped notification leads. The server sends a `link` such as `/invoices/5`.
enum PushRoute: Hashable, Identifiable {
    case renewals
    case invoice(Int)
    case original(Int)

    var id: Self { self }

    init?(kind: String?, link: String?) {
        if kind == ReminderKind.renewalDraft.rawValue {
            self = .renewals
            return
        }
        let parts = (link ?? "").split(separator: "/")
        guard parts.count == 2, let id = Int(parts[1]), id > 0 else { return nil }
        switch parts[0] {
        case "invoices": self = .invoice(id)
        case "originals": self = .original(id)
        default: return nil
        }
    }
}

/// Reminder notifications: asks permission, sends the device token to the server, and turns a
/// tapped notification into a route. A route set while the app is locked waits for `MainTabs`.
@MainActor
@Observable
final class PushCenter: NSObject {
    /// Set before launch finishes, so `AppDelegate` can pass on the device token.
    static weak var current: PushCenter?

    var route: PushRoute?

    @ObservationIgnored private let api: APIClient

    init(api: APIClient) {
        self.api = api
        super.init()
        Self.current = self
        // This must happen before launch finishes, or a tap that launched the app is lost.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once, then reuses the answer. Registers on every open, because Apple can change the
    /// token, and the server ignores a token it already has.
    func start() async {
        #if DEBUG
        // UI tests cannot get past the system permission sheet. This is not in Release builds.
        if UserDefaults.standard.bool(forKey: "skipPushPrompt") { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if allowed { UIApplication.shared.registerForRemoteNotifications() }
    }

    func register(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { [api] in
            #if DEBUG
            try? await api.registerDevice(token: token, environment: "sandbox")
            #else
            try? await api.registerDevice(token: token, environment: "production")
            #endif
        }
    }

    fileprivate func open(reminderId: Int?, kind: String?, link: String?) {
        route = PushRoute(kind: kind, link: link)
        guard let reminderId else { return }
        Task { [api] in try? await api.markReminderRead(id: reminderId) }
    }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    /// Shows the banner while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let reminderId = info["reminderId"] as? Int
        let kind = info["kind"] as? String
        let link = info["link"] as? String
        await open(reminderId: reminderId, kind: kind, link: link)
    }
}

/// Only here because the device token still arrives through the app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushCenter.current?.register(deviceToken: deviceToken)
    }
}
