import AppKit
import Foundation
@preconcurrency import UserNotifications

/// What a first-contact notification says, as the design's banner shows it: "Raycast reached a new site" over
/// "notion.com · first host api.notion.com · via node", led by the Mac's name when another Mac found it.
enum CaptureAlertText {
    @MainActor
    static func title(appName: String, alert: AlertItem) -> String {
        switch alert.scope {
        case .site: trf("%@ reached a new site", "Capture", appName)
        case .host: trf("%@ contacted a new host", "Capture", appName)
        case .ip:
            alert.isDirect
                ? trf("%@ connected straight to a new IP", "Capture", appName)
                : trf("%@ connected to a new IP", "Capture", appName)
        }
    }

    /// The new site and its first host, or the new host or IP, then the process. `deviceName` leads alerts that
    /// another Mac found.
    @MainActor
    static func details(alert: AlertItem, deviceName: String? = nil) -> String {
        var parts: [String] = []
        if let deviceName, !deviceName.isEmpty { parts.append(deviceName) }
        if alert.scope == .site, let site = alert.site, !site.isEmpty {
            parts.append(site)
            parts.append(trf("first host %@", "Capture", alert.value))
        } else {
            parts.append(alert.value)
        }
        if let process = alert.knownProcessName { parts.append(trf("via %@", "Capture", process)) }
        return parts.joined(separator: " · ")
    }
}

/// At most one notification per app per burst window: later alerts of the same app replace the pending
/// notification with an aggregated one.
struct CaptureBurstGrouper {
    enum Decision: Equatable {
        /// Post a new notification.
        case post(identifier: String)
        /// Replace notification `identifier`, whose first alert is `first`, adding `extra` more alerts.
        case aggregate(identifier: String, first: AlertItem, extra: [AlertItem])
    }

    private struct Burst {
        var identifier: String
        var startedAt: Date
        var alerts: [AlertItem]
    }

    let window: TimeInterval
    private var bursts: [AppID: Burst] = [:]

    init(window: TimeInterval = 30) {
        self.window = window
    }

    mutating func add(_ alert: AlertItem, now: Date = .now) -> Decision {
        bursts = bursts.filter { now.timeIntervalSince($0.value.startedAt) < window }
        if var burst = bursts[alert.appID] {
            burst.alerts.append(alert)
            bursts[alert.appID] = burst
            return .aggregate(identifier: burst.identifier, first: burst.alerts[0], extra: Array(burst.alerts.dropFirst()))
        }
        let identifier = "alert-\(alert.appID.uuidString)-\(alert.id)-\(Int(now.timeIntervalSince1970 * 1000))"
        bursts[alert.appID] = Burst(identifier: identifier, startedAt: now, alerts: [alert])
        return .post(identifier: identifier)
    }
}

/// Posts first-contact notifications and handles their actions ("View", "Mute Host").
@MainActor
final class CaptureNotifier: NSObject {
    static let categoryIdentifier = "tidemark.alert"
    static let viewAction = "tidemark.alert.view"
    static let muteAction = "tidemark.alert.mute"

    /// Opens an app's inventory for these alerts (marking them read).
    var onView: ((AppID, [Int64]) -> Void)?
    /// Mutes a host or IP, dismissing an alert.
    var onMute: ((String, Int64?) -> Void)?
    /// Hands a notification to Notification Center; tests replace it so nothing reaches the screen.
    var deliver: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }

    private var grouper = CaptureBurstGrouper()
    private var installed = false

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Registers the delegate and the alert category, and asks for permission to notify. Call once at launch.
    func install() {
        guard !installed else { return }
        installed = true
        center.delegate = self
        let view = UNNotificationAction(identifier: Self.viewAction, title: tr("View", "Capture"), options: [.foreground])
        let mute = UNNotificationAction(identifier: Self.muteAction, title: tr("Mute Host", "Capture"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [view, mute], intentIdentifiers: [], options: [])
        ])
        let center = self.center
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// Posts a notification for `alert`, or folds it into the notification of its app's current burst.
    func post(_ alert: AlertItem, appName: String, deviceName: String?, now: Date = .now) {
        switch grouper.add(alert, now: now) {
        case .post(let identifier):
            add(identifier: identifier, text: Text(
                headline: CaptureAlertText.title(appName: appName, alert: alert),
                details: CaptureAlertText.details(alert: alert, deviceName: deviceName),
                silent: false, appID: alert.appID, alertIDs: [alert.id], muteValue: alert.value
            ))
        case .aggregate(let identifier, let first, let extra):
            let values = extra.map { $0.scope == .site ? ($0.site ?? $0.value) : $0.value }
            let more = trf("…and %lld more: %@", "Capture", extra.count, values.joined(separator: ", "))
            // The burst already alerted once; the update is silent.
            add(identifier: identifier, text: Text(
                headline: CaptureAlertText.title(appName: appName, alert: first),
                details: CaptureAlertText.details(alert: first, deviceName: deviceName) + "\n" + more,
                silent: true, appID: alert.appID, alertIDs: [first.id] + extra.map(\.id), muteValue: first.value
            ))
        }
    }

    /// What one notification says (built into `UNNotificationContent` on delivery).
    private struct Text {
        var headline: String
        var details: String
        var silent: Bool
        var appID: AppID
        var alertIDs: [Int64]
        var muteValue: String
    }

    /// Lays the text out like the design's banner: "Tidemark" on top (with the time beside it), the headline, then
    /// the details.
    private func add(identifier: String, text: Text) {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = text.appID.uuidString
        content.title = "Tidemark"
        content.subtitle = text.headline
        content.body = text.details
        if text.silent {
            content.sound = nil
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        content.userInfo = Self.userInfo(appID: text.appID, alertIDs: text.alertIDs, muteValue: text.muteValue, alertID: text.alertIDs.first ?? 0)
        deliver(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private static func userInfo(appID: AppID, alertIDs: [Int64], muteValue: String, alertID: Int64) -> [String: Any] {
        ["appID": appID.uuidString, "alertIDs": alertIDs.map { NSNumber(value: $0) }, "mute": muteValue, "alertID": NSNumber(value: alertID)]
    }

    /// Brings the main window forward. The engine cannot call `openWindow`, so it orders the existing
    /// window with identifier `main` front.
    static func showMainWindow() {
        NSApp.activate()
        let window = NSApp.windows.first { window in
            guard let id = window.identifier?.rawValue else { return false }
            return id == WindowID.main || id.hasPrefix(WindowID.main + "-")
        }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    fileprivate func handle(action: String, appID: AppID?, alertIDs: [Int64], muteValue: String?, alertID: Int64?) {
        switch action {
        case Self.muteAction:
            if let muteValue { onMute?(muteValue, alertID) }
        case Self.viewAction, UNNotificationDefaultActionIdentifier:
            if let appID { onView?(appID, alertIDs) }
            Self.showMainWindow()
        default:
            break
        }
    }
}

extension CaptureNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let appID = (info["appID"] as? String).flatMap(UUID.init(uuidString:))
        let alertIDs = (info["alertIDs"] as? [NSNumber])?.map(\.int64Value) ?? []
        let muteValue = info["mute"] as? String
        let alertID = (info["alertID"] as? NSNumber)?.int64Value
        await handle(action: action, appID: appID, alertIDs: alertIDs, muteValue: muteValue, alertID: alertID)
    }
}
