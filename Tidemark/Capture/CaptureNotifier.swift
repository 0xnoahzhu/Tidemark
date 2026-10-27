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

/// At most one notification per app and Mac per burst window: later alerts of the same app from the same Mac
/// replace the pending notification with an aggregated one (which names that Mac once, like its first alert).
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

    private struct Source: Hashable {
        var app: AppID
        var device: DeviceID
    }

    let window: TimeInterval
    private var bursts: [Source: Burst] = [:]

    init(window: TimeInterval = 30) {
        self.window = window
    }

    mutating func add(_ alert: AlertItem, now: Date = .now) -> Decision {
        bursts = bursts.filter { now.timeIntervalSince($0.value.startedAt) < window }
        let source = Source(app: alert.appID, device: alert.deviceID)
        if var burst = bursts[source] {
            burst.alerts.append(alert)
            bursts[source] = burst
            return .aggregate(identifier: burst.identifier, first: burst.alerts[0], extra: Array(burst.alerts.dropFirst()))
        }
        let identifier = "alert-\(alert.appID.uuidString)-\(alert.id)-\(Int(now.timeIntervalSince1970 * 1000))"
        bursts[source] = Burst(identifier: identifier, startedAt: now, alerts: [alert])
        return .post(identifier: identifier)
    }
}

/// Posts first-contact notifications and handles their actions: "View" (also what clicking one does) and "Show Request".
@MainActor
final class CaptureNotifier: NSObject {
    nonisolated static let categoryIdentifier = "tidemark.alert"
    nonisolated static let viewAction = "tidemark.alert.view"
    nonisolated static let showRequestAction = "tidemark.alert.request"

    /// Opens an app's inventory for these alerts (marking them read).
    var onView: ((AppID, [Int64]) -> Void)?
    /// Opens the request that raised the notification's (first) alert in History, marking these alerts read.
    var onShowRequest: ((RequestTarget, [Int64]) -> Void)?
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
        center.setNotificationCategories([Self.category])
        let center = self.center
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// The alert category: "View", then "Show Request".
    static var category: UNNotificationCategory {
        let view = UNNotificationAction(identifier: viewAction, title: tr("View", "Capture"), options: [.foreground])
        let request = UNNotificationAction(identifier: showRequestAction, title: tr("Show Request", "Capture"), options: [.foreground])
        return UNNotificationCategory(identifier: categoryIdentifier, actions: [view, request], intentIdentifiers: [], options: [])
    }

    /// Posts a notification for `alert`, or folds it into the notification of its app's current burst.
    func post(_ alert: AlertItem, appName: String, deviceName: String?, now: Date = .now) {
        switch grouper.add(alert, now: now) {
        case .post(let identifier):
            add(identifier: identifier, text: Text(
                headline: CaptureAlertText.title(appName: appName, alert: alert),
                details: CaptureAlertText.details(alert: alert, deviceName: deviceName),
                silent: false, appID: alert.appID, alertIDs: [alert.id], request: RequestTarget(alert)
            ))
        case .aggregate(let identifier, let first, let extra):
            let values = extra.map { $0.scope == .site ? ($0.site ?? $0.value) : $0.value }
            let more = trf("…and %lld more: %@", "Capture", extra.count, values.joined(separator: ", "))
            // The burst already alerted once; the update is silent. Its headline, and so its request, is the first alert's.
            add(identifier: identifier, text: Text(
                headline: CaptureAlertText.title(appName: appName, alert: first),
                details: CaptureAlertText.details(alert: first, deviceName: deviceName) + "\n" + more,
                silent: true, appID: alert.appID, alertIDs: [first.id] + extra.map(\.id), request: RequestTarget(first)
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
        /// What Show Request opens: the request of the alert the headline names.
        var request: RequestTarget
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
        content.userInfo = Self.userInfo(appID: text.appID, alertIDs: text.alertIDs, request: text.request)
        deliver(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func userInfo(appID: AppID, alertIDs: [Int64], request: RequestTarget) -> [String: Any] {
        var info: [String: Any] = [
            "appID": appID.uuidString, "alertIDs": alertIDs.map { NSNumber(value: $0) },
            "hostKind": request.kind.rawValue, "hostValue": request.value,
        ]
        if let rowID = request.rowID { info["requestRowID"] = NSNumber(value: rowID) }
        return info
    }

    /// Where an action on a notification leads.
    enum Route: Equatable, Sendable {
        /// The app's Domains & IPs.
        case view(AppID, alertIDs: [Int64])
        /// The request in History.
        case showRequest(RequestTarget, alertIDs: [Int64])
    }

    /// Where `action` on a notification with `userInfo` leads: nil for a dismissal, or a notification Tidemark did not
    /// post. A notification posted before Show Request existed (the category, and so its actions, are this build's)
    /// names no request: it opens the app's Domains & IPs, as View does.
    nonisolated static func route(action: String, userInfo: [AnyHashable: Any]) -> Route? {
        guard let appID = (userInfo["appID"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        let alertIDs = (userInfo["alertIDs"] as? [NSNumber])?.map(\.int64Value) ?? []
        switch action {
        case viewAction, UNNotificationDefaultActionIdentifier:
            return .view(appID, alertIDs: alertIDs)
        case showRequestAction:
            guard let kind = (userInfo["hostKind"] as? String).flatMap(HostKind.init(rawValue:)),
                  let value = userInfo["hostValue"] as? String else { return .view(appID, alertIDs: alertIDs) }
            let rowID = (userInfo["requestRowID"] as? NSNumber)?.int64Value
            return .showRequest(RequestTarget(rowID: rowID, kind: kind, value: value, appID: appID), alertIDs: alertIDs)
        default:
            return nil
        }
    }

    /// Brings the main window forward. The engine cannot call `openWindow`, so it orders the existing
    /// window with identifier `main` front.
    static func showMainWindow() {
        DockPresence.willShowWindow()
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

    func handle(_ route: Route) {
        switch route {
        case .view(let appID, let alertIDs):
            onView?(appID, alertIDs)
        case .showRequest(let request, let alertIDs):
            onShowRequest?(request, alertIDs)
        }
        Self.showMainWindow()
    }
}

extension CaptureNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let route = Self.route(action: response.actionIdentifier, userInfo: response.notification.request.content.userInfo) else { return }
        await handle(route)
    }
}
