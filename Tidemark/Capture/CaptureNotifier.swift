import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Titles and subtitles of first-contact alerts, matching the design:
/// "Cursor reached a new site, notion.com" · "First host api.notion.com · via node · US · AS13335 Cloudflare".
enum CaptureAlertText {
    @MainActor
    static func title(appName: String, alert: AlertItem) -> String {
        switch alert.scope {
        case .site: trf("%1$@ reached a new site, %2$@", "Capture", appName, alert.site ?? alert.value)
        case .host: trf("%1$@ contacted %2$@", "Capture", appName, alert.value)
        case .ip:
            alert.isDirect
                ? trf("%1$@ connected straight to %2$@", "Capture", appName, alert.value)
                : trf("%1$@ connected to %2$@", "Capture", appName, alert.value)
        }
    }

    /// `deviceName` prefixes alerts that another Mac found.
    @MainActor
    static func subtitle(alert: AlertItem, deviceName: String? = nil) -> String {
        var parts: [String] = []
        if let deviceName, !deviceName.isEmpty { parts.append(deviceName) }
        let via = trf("via %@", "Capture", alert.processName)
        let geo = alert.geo?.display ?? ""
        switch alert.scope {
        case .site:
            parts.append(trf("First host %@", "Capture", alert.value))
            parts.append(via)
        case .host:
            parts.append(via)
            if let ip = alert.ip, !ip.isEmpty { parts.append(ip) }
        case .ip:
            if let host = alert.host, !host.isEmpty { parts.append(host) } else { parts.append(tr("No hostname", "Capture")) }
            parts.append(via)
        }
        if !geo.isEmpty { parts.append(geo) }
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

    mutating func add(_ alert: AlertItem, grouping: Bool, now: Date = .now) -> Decision {
        bursts = bursts.filter { now.timeIntervalSince($0.value.startedAt) < window }
        if grouping, var burst = bursts[alert.appID] {
            burst.alerts.append(alert)
            bursts[alert.appID] = burst
            return .aggregate(identifier: burst.identifier, first: burst.alerts[0], extra: Array(burst.alerts.dropFirst()))
        }
        let identifier = "alert-\(alert.appID.uuidString)-\(alert.id)-\(Int(now.timeIntervalSince1970 * 1000))"
        if grouping { bursts[alert.appID] = Burst(identifier: identifier, startedAt: now, alerts: [alert]) }
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

    private var grouper = CaptureBurstGrouper()
    private var installed = false
    private var authorizationRequested = false

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Registers the delegate and the alert category. Call once at launch.
    func install() {
        guard !installed else { return }
        installed = true
        center.delegate = self
        let view = UNNotificationAction(identifier: Self.viewAction, title: tr("View", "Capture"), options: [.foreground])
        let mute = UNNotificationAction(identifier: Self.muteAction, title: tr("Mute Host", "Capture"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [view, mute], intentIdentifiers: [], options: [])
        ])
    }

    /// Asks for permission the first time notifications are enabled.
    func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Posts (or folds into the current burst) a notification for `alert`.
    func post(_ alert: AlertItem, appName: String, deviceName: String?, groupBursts: Bool, now: Date = .now) {
        let decision = grouper.add(alert, grouping: groupBursts, now: now)
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = alert.appID.uuidString
        switch decision {
        case .post(let identifier):
            content.title = CaptureAlertText.title(appName: appName, alert: alert)
            content.subtitle = CaptureAlertText.subtitle(alert: alert, deviceName: deviceName)
            content.sound = .default
            content.userInfo = Self.userInfo(appID: alert.appID, alertIDs: [alert.id], muteValue: alert.value, alertID: alert.id)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        case .aggregate(let identifier, let first, let extra):
            content.title = CaptureAlertText.title(appName: appName, alert: first)
            content.subtitle = CaptureAlertText.subtitle(alert: first, deviceName: deviceName)
            let values = extra.map { $0.scope == .site ? ($0.site ?? $0.value) : $0.value }
            content.body = trf("…and %lld more: %@", "Capture", extra.count, values.joined(separator: ", "))
            // The burst already alerted once; the update is silent.
            content.sound = nil
            content.interruptionLevel = .passive
            content.userInfo = Self.userInfo(appID: alert.appID, alertIDs: [first.id] + extra.map(\.id), muteValue: first.value, alertID: first.id)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
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
