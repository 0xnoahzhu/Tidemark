#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Sample data for SwiftUI previews and for checking the main window without Surge or PostgreSQL.
///
/// Launch a Debug build with `-TidemarkUIDemo YES` to fill the observable state with the prototype's
/// Macs, apps, requests and alerts, an in-memory History database and a slow synthetic request stream.
/// Nothing is written anywhere. Optional launch arguments:
/// * `-TidemarkUIDemoPage notifications|history|inspector` opens that page;
/// * `-TidemarkUIDemoStill YES` stops the synthetic stream;
/// * `-TidemarkUIDemoSnapshot <file.png>` writes the main window (and its view tree, as `.txt`) after 3 s.
@MainActor
enum ShellDemoData {
    static let defaultsKey = "TidemarkUIDemo"

    private static var installed = false

    static func installIfRequested(into model: AppModel) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: defaultsKey), !installed else { return }
        installed = true
        install(into: model)
        switch defaults.string(forKey: "TidemarkUIDemoPage") {
        case "notifications": model.nav.open(.notifications)
        case "history": model.nav.requestsLive = false
        case "inspector":
            Task {
                try? await Task.sleep(for: .seconds(1))
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    model.nav.selectedRequest = model.live.rows.dropFirst(3).first?.key
                }
            }
        default: break
        }
        if !defaults.bool(forKey: "TidemarkUIDemoStill") {
            Task { await stream(into: model) }
        }
        if let path = defaults.string(forKey: "TidemarkUIDemoSnapshot") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                snapshotMainWindow(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Renders the main window's content into a PNG (layout check without screen recording access).
    private static func snapshotMainWindow(to url: URL) {
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true } ?? NSApp.mainWindow
        guard let view = window?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        var lines: [String] = []
        dumpHierarchy(view, depth: 0, into: &lines)
        try? lines.joined(separator: "\n").write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    /// Writes the AppKit view tree with window-space frames next to the snapshot (glass is not captured).
    private static func dumpHierarchy(_ view: NSView, depth: Int, into lines: inout [String]) {
        guard depth < 14 else { return }
        let frame = view.convert(view.bounds, to: nil)
        lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\(view.isHidden ? " hidden" : "")")
        for sub in view.subviews { dumpHierarchy(sub, depth: depth + 1, into: &lines) }
    }

    static func install(into model: AppModel, now: Date = .now) {
        let this = model.devices.thisDeviceID
        let mini = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let studio = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        model.devices.devices = [
            Device(id: this, name: "MacBook Pro", model: "MacBook Pro · M3 Pro", shortName: "MBP", hue: 240, isRemoteSurge: false, rowCount: 1_284_093, lastWriteAt: now, createdAt: now.addingTimeInterval(-86400 * 40)),
            Device(id: mini, name: "Mac mini (Office)", model: "Mac mini · M4", shortName: "mini", hue: 150, isRemoteSurge: false, rowCount: 3_918_442, lastWriteAt: now.addingTimeInterval(-2), createdAt: now.addingTimeInterval(-86400 * 90)),
            Device(id: studio, name: "Mac Studio (Home)", model: "Mac Studio · M2 Max", shortName: "Std", hue: 65, isRemoteSurge: false, rowCount: 612_300, lastWriteAt: now.addingTimeInterval(-3 * 3600), createdAt: now.addingTimeInterval(-86400 * 120)),
        ]

        let apps = [
            demoApp("Cursor", "/Applications/Cursor.app", "C", 260, days: 21),
            demoApp("WeChat", "/Applications/WeChat.app", "W", 150, days: 18),
            demoApp("Raycast", "/Applications/Raycast.app", "R", 25, days: 12),
            demoApp("Docker", "/Applications/Docker.app", "D", 230, days: 9),
            demoApp("Figma", "/Applications/Figma.app", "F", 300, days: 30, archived: true),
        ]
        model.catalog.apps = apps
        let newCounts = [5, 4, 4, 1, 0]
        for (app, n) in zip(apps, newCounts) {
            model.catalog.stats[app.id] = AppStats(domains: 40, ips: 22, requests: 9_412, processes: 6, newIn24h: n)
            model.catalog.installs[app.id] = [this: true, mini: app.name != "Raycast", studio: app.name == "Cursor"]
        }

        model.live.surge = .connected(detail: "Surge Mac 6.10 · rule mode")
        model.live.database = .connected(detail: "PostgreSQL 17.4 · 2 ms")
        model.live.totalRows = 1_284_093
        model.live.writtenThisSession = 44
        model.live.rate = 2.2

        var rows: [RequestRecord] = []
        for i in 0..<60 {
            rows.append(sampleRow(index: i, startedAt: now.addingTimeInterval(-Double(i) * 0.9 - 2), model: model, apps: apps, devices: [this, this, mini]))
        }
        model.live.rows = rows

        // A day of history with a daily rhythm for the History view.
        var history: [RequestRecord] = []
        var t = now.addingTimeInterval(-60)
        var i = 100
        while t > now.addingTimeInterval(-86400) {
            let hour = Calendar.current.component(.hour, from: t)
            let busy = 0.35 + 0.65 * (1 + sin(Double(hour - 9) / 24 * 2 * .pi)) / 2
            t = t.addingTimeInterval(-(40 + 160 * (1 - busy)) * Double.random(in: 0.6...1.4))
            history.append(sampleRow(index: i, startedAt: t, model: model, apps: apps, devices: [this, this, mini]))
            i += 1
        }
        model.database = ShellDemoDatabase(rows: rows + history, appNames: Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.name) }))

        let cursor = apps[0], raycast = apps[2], docker = apps[3], wechat = apps[1]
        let cf = GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc.")
        model.alerts.items = [
            demoAlert(1, cursor, this, .host, "raw.githubusercontent.com", site: "githubusercontent.com", ip: "185.199.108.133", geo: GeoInfo(countryCode: "US", asn: 54113, organization: "Fastly, Inc."), process: "node", at: now.addingTimeInterval(-600)),
            demoAlert(2, raycast, this, .site, "api.linear.app", site: "linear.app", ip: "104.18.36.12", geo: cf, process: "node", at: now.addingTimeInterval(-1200)),
            demoAlert(3, docker, this, .ip, "104.16.98.215", host: "production.cloudflare.docker.com", geo: cf, process: "com.docker.backend", at: now.addingTimeInterval(-3000)),
            demoAlert(4, raycast, this, .site, "api.notion.com", site: "notion.com", geo: cf, process: "node", at: now.addingTimeInterval(-5000), read: true),
            demoAlert(5, wechat, this, .ip, "157.148.69.80", geo: GeoInfo(countryCode: "CN", asn: 4837, organization: "China Unicom"), process: "WeChat", direct: true, at: now.addingTimeInterval(-86400 - 600), read: true),
            demoAlert(6, raycast, mini, .site, "api.openai.com", site: "openai.com", geo: cf, process: "Raycast", at: now.addingTimeInterval(-86400 - 3000), read: true),
        ]
        model.alerts.unreadCount = model.alerts.items.filter(\.isUnread).count
    }

    private static func stream(into model: AppModel) async {
        var index = 1000
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1300)))
            guard model.live.recording else { continue }
            let apps = model.catalog.active
            guard !apps.isEmpty else { continue }
            index += 1
            let row = sampleRow(index: index, startedAt: .now, model: model, apps: apps, devices: model.devices.devices.prefix(2).map(\.id))
            model.live.upsert([row])
            model.live.writtenThisSession += 1
            model.live.totalRows += 1
            model.live.rate = Double.random(in: 1.6...3.2)
        }
    }

    private static func demoApp(_ name: String, _ path: String, _ letter: String, _ hue: Double, days: Double, archived: Bool = false) -> MonitoredApp {
        MonitoredApp(id: UUID(), name: name, path: path, bundleID: nil, tileLetter: letter, tileHue: hue, includeChildren: true,
                     alertRule: .site, alertNewIP: true, archivedAt: archived ? .now : nil, createdAt: .now.addingTimeInterval(-86400 * days))
    }

    private static func demoAlert(_ id: Int64, _ app: MonitoredApp, _ device: DeviceID, _ scope: AlertScope, _ value: String,
                                  site: String? = nil, host: String? = nil, ip: String? = nil, geo: GeoInfo?, process: String,
                                  direct: Bool = false, at date: Date, read: Bool = false) -> AlertItem {
        AlertItem(id: id, deviceID: device, appID: app.id, kind: scope == .ip ? .ip : .domain, scope: scope, value: value, site: site,
                  host: host, ip: ip, geo: geo, processName: process, isDirect: direct, requestRowID: nil, createdAt: date,
                  readAt: read ? date : nil)
    }

    private static let hosts: [(String, String, [String], String)] = [
        ("api2.cursor.sh", "104.18.19.125", ["AI", "US-West"], "HTTPS"),
        ("registry.npmjs.org", "104.16.27.34", ["Proxy", "HK-01"], "HTTPS"),
        ("api.github.com", "20.205.243.168", ["Proxy", "HK-01"], "HTTPS"),
        ("courier.push.apple.com", "17.57.146.20", ["DIRECT"], "TCP"),
        ("res.wx.qq.com", "58.251.111.103", ["DIRECT"], "HTTPS"),
        ("183.3.226.35", "183.3.226.35", ["DIRECT"], "TCP"),
        ("backend.raycast.com", "76.76.21.21", ["Proxy", "JP-02"], "HTTPS"),
        ("production.cloudflare.docker.com", "104.16.98.215", ["Proxy", "JP-02"], "HTTPS"),
        ("time.apple.com", "17.253.84.253", ["DIRECT"], "UDP"),
    ]

    private static func sampleRow(index: Int, startedAt: Date, model: AppModel, apps: [MonitoredApp], devices: [DeviceID]) -> RequestRecord {
        let pick = hosts[index % hosts.count]
        let app = apps[index % apps.count]
        let device = devices[index % max(1, devices.count)]
        let unmonitored = index % 5 == 3
        let chain: [ProcessLink] = unmonitored
            ? [ProcessLink(name: "apsd", pid: 412, path: "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd")]
            : [ProcessLink(name: app.name, pid: 812, path: app.path + "/Contents/MacOS/\(app.name)"),
               ProcessLink(name: "\(app.name) Helper (Plugin)", pid: 851, path: app.path + "/Contents/Frameworks/\(app.name) Helper (Plugin).app/Contents/MacOS/\(app.name) Helper (Plugin)"),
               ProcessLink(name: "node", pid: Int32(1201 + index % 7), path: "/usr/local/bin/node")]
        let failed = index % 17 == 6
        let active = index % 6 == 0
        let size = Int64((index * 7919) % 900_000 + 400)
        return RequestRecord(
            key: RequestKey(deviceID: device, session: 1_729_700_000_000, surgeID: Int64(index)),
            rowID: index % 9 == 0 ? nil : Int64(1_284_000 + index),
            startedAt: startedAt, setupCompletedAt: startedAt.addingTimeInterval(0.09),
            completedAt: active ? nil : startedAt.addingTimeInterval(0.16),
            method: pick.3, host: pick.0, port: 443, url: pick.0 + ":443",
            remoteIP: pick.1, remoteAddress: pick.1, geo: GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc."),
            policyPath: pick.2, rule: "DOMAIN-SUFFIX,\(pick.0.split(separator: ".").suffix(2).joined(separator: "."))",
            state: failed ? .failed : (active ? .active : .completed), inBytes: size, outBytes: size / 9,
            pid: chain.last?.pid, processPath: chain.last?.path, bundlePath: unmonitored ? nil : app.path, chain: chain,
            appID: unmonitored ? nil : app.id, localAddress: "192.168.31.24:\(51000 + index % 900)", interface: "en0",
            notes: [], isNew: index % 23 == 4, writtenAt: index % 9 == 0 ? nil : startedAt.addingTimeInterval(0.4), probeSessionID: nil
        )
    }

    /// A model filled with the demo data, for previews.
    static func previewModel() -> AppModel {
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: "TidemarkPreview") ?? .standard))
        install(into: model)
        return model
    }
}

#Preview("Main window") {
    MainWindowView()
        .environment(ShellDemoData.previewModel())
        .environment(Localizer.shared)
        .frame(width: 1248, height: 812)
}

#Preview("Notifications") {
    let model = ShellDemoData.previewModel()
    model.nav.open(.notifications)
    return MainWindowView()
        .environment(model)
        .environment(Localizer.shared)
        .frame(width: 1248, height: 812)
}
#endif
