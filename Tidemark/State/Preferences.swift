import Foundation
import Observation

/// Per-Mac settings, persisted in `UserDefaults`. Shared settings (apps, mutes) live in PostgreSQL.
@MainActor
@Observable
final class Preferences {
    enum ShowIn: String, CaseIterable, Sendable { case menuBarAndDock, menuBarOnly }
    enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    enum Language: String, CaseIterable, Sendable { case system, english, chinese }
    /// Service asked for the network type (hosting, residential…) of egress IPs and looked-up IPs.
    enum IPInfoService: String, CaseIterable, Sendable { case proxycheck, off }

    /// Write batching presets offered in Settings › Database ("200 · 1 s").
    struct BatchPreset: Hashable, Sendable {
        var rows: Int
        var interval: Double
        static let all: [BatchPreset] = [
            .init(rows: 100, interval: 0.5), .init(rows: 200, interval: 1), .init(rows: 500, interval: 2), .init(rows: 1000, interval: 5),
        ]
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Identity
    /// This Mac's row in `devices`; generated once.
    let thisDeviceID: DeviceID

    // MARK: Surge
    var surgeCLIPath: String { didSet { set(surgeCLIPath, "surge.cliPath") } }
    /// `host:port` of a remote Surge controller, empty for the local one.
    var surgeRemote: String { didSet { set(surgeRemote, "surge.remote") } }
    /// Device name stored with requests from the remote Surge.
    var surgeRemoteTag: String { didSet { set(surgeRemoteTag, "surge.remoteTag") } }
    var surgeReconnect: Bool { didSet { set(surgeReconnect, "surge.reconnect") } }

    // MARK: Database
    /// PostgreSQL URL without the password (the password is kept in the Keychain).
    var databaseURL: String { didSet { set(databaseURL, "db.url") } }
    var batchRows: Int { didSet { set(batchRows, "db.batchRows") } }
    var batchInterval: Double { didSet { set(batchInterval, "db.batchInterval") } }
    /// Rows buffered on disk while the database is unreachable.
    var spoolLimit: Int { didSet { set(spoolLimit, "db.spoolLimit") } }
    /// Days to keep requests; 0 keeps them forever.
    var retentionDays: Int { didSet { set(retentionDays, "db.retentionDays") } }

    // MARK: Notifications
    var systemNotifications: Bool { didSet { set(systemNotifications, "notify.system") } }
    var notifyNewDomain: Bool { didSet { set(notifyNewDomain, "notify.newDomain") } }
    var notifyNewIP: Bool { didSet { set(notifyNewIP, "notify.newIP") } }
    var notifyOtherMacs: Bool { didSet { set(notifyOtherMacs, "notify.otherMacs") } }
    var groupBursts: Bool { didSet { set(groupBursts, "notify.groupBursts") } }
    /// Add an on-device one-line explanation of the host to new-host notifications.
    var notifyExplainHosts: Bool { didSet { set(notifyExplainHosts, "notify.explainHosts") } }

    // MARK: General
    var showIn: ShowIn { didSet { set(showIn.rawValue, "general.showIn") } }
    var appearance: Appearance { didSet { set(appearance.rawValue, "general.appearance") } }
    /// Liquid Glass amount, 0 (clear) … 100 (tinted).
    var glass: Double { didSet { set(glass, "general.glass") } }
    var language: Language { didSet { set(language.rawValue, "general.language") } }
    var openAtLogin: Bool { didSet { set(openAtLogin, "general.openAtLogin") } }
    var ipInfoService: IPInfoService { didSet { set(ipInfoService.rawValue, "general.ipInfoService") } }

    // MARK: Requests view
    var hideAppleServices: Bool { didSet { set(hideAppleServices, "requests.hideApple") } }
    var monitoredOnly: Bool { didSet { set(monitoredOnly, "requests.monitoredOnly") } }

    // MARK: Site probe
    var probeIsolated: Bool { didSet { set(probeIsolated, "probe.isolated") } }
    var probeTail: Bool { didSet { set(probeTail, "probe.tail") } }
    var probeOwnWindow: Bool { didSet { set(probeOwnWindow, "probe.ownWindow") } }
    var probeMode: ProbeDeviceMode { didSet { set(probeMode.rawValue, "probe.mode") } }
    /// Send the Global Privacy Control signal from the probe browser.
    var probeGlobalPrivacyControl: Bool { didSet { set(probeGlobalPrivacyControl, "probe.globalPrivacyControl") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let s = defaults.string(forKey: "device.id"), let id = UUID(uuidString: s) {
            thisDeviceID = id
        } else {
            let id = UUID()
            defaults.set(id.uuidString, forKey: "device.id")
            thisDeviceID = id
        }
        let cli = SurgeEndpoint.defaultCLIPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? SurgeEndpoint.defaultCLIPaths[0]
        surgeCLIPath = defaults.string(forKey: "surge.cliPath") ?? cli
        surgeRemote = defaults.string(forKey: "surge.remote") ?? ""
        surgeRemoteTag = defaults.string(forKey: "surge.remoteTag") ?? ""
        surgeReconnect = defaults.object(forKey: "surge.reconnect") as? Bool ?? true

        databaseURL = defaults.string(forKey: "db.url") ?? "postgresql://localhost:5432/tidemark"
        batchRows = defaults.object(forKey: "db.batchRows") as? Int ?? 200
        batchInterval = defaults.object(forKey: "db.batchInterval") as? Double ?? 1
        spoolLimit = defaults.object(forKey: "db.spoolLimit") as? Int ?? 500_000
        retentionDays = defaults.object(forKey: "db.retentionDays") as? Int ?? 0

        systemNotifications = defaults.object(forKey: "notify.system") as? Bool ?? true
        notifyNewDomain = defaults.object(forKey: "notify.newDomain") as? Bool ?? true
        notifyNewIP = defaults.object(forKey: "notify.newIP") as? Bool ?? true
        notifyOtherMacs = defaults.object(forKey: "notify.otherMacs") as? Bool ?? false
        groupBursts = defaults.object(forKey: "notify.groupBursts") as? Bool ?? true
        notifyExplainHosts = defaults.object(forKey: "notify.explainHosts") as? Bool ?? false

        showIn = defaults.string(forKey: "general.showIn").flatMap(ShowIn.init(rawValue:)) ?? .menuBarAndDock
        appearance = defaults.string(forKey: "general.appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        glass = defaults.object(forKey: "general.glass") as? Double ?? 40
        language = defaults.string(forKey: "general.language").flatMap(Language.init(rawValue:)) ?? .system
        openAtLogin = defaults.object(forKey: "general.openAtLogin") as? Bool ?? true
        ipInfoService = defaults.string(forKey: "general.ipInfoService").flatMap(IPInfoService.init(rawValue:)) ?? .proxycheck

        hideAppleServices = defaults.object(forKey: "requests.hideApple") as? Bool ?? false
        monitoredOnly = defaults.object(forKey: "requests.monitoredOnly") as? Bool ?? false

        probeIsolated = defaults.object(forKey: "probe.isolated") as? Bool ?? true
        probeTail = defaults.object(forKey: "probe.tail") as? Bool ?? true
        probeOwnWindow = defaults.object(forKey: "probe.ownWindow") as? Bool ?? true
        probeMode = defaults.string(forKey: "probe.mode").flatMap(ProbeDeviceMode.init(rawValue:)) ?? .desktop
        probeGlobalPrivacyControl = defaults.object(forKey: "probe.globalPrivacyControl") as? Bool ?? false
    }

    var batchPreset: BatchPreset {
        get { BatchPreset(rows: batchRows, interval: batchInterval) }
        set { batchRows = newValue.rows; batchInterval = newValue.interval }
    }

    var surgeEndpoint: SurgeEndpoint {
        let remote = surgeRemote.trimmingCharacters(in: .whitespaces)
        return SurgeEndpoint(
            cliPath: surgeCLIPath,
            remote: remote.isEmpty ? nil : remote,
            password: remote.isEmpty ? nil : Keychain.read(account: Keychain.surgeRemoteAccount)
        )
    }

    /// Full connection URL including the Keychain password.
    /// `TIDEMARK_DATABASE_URL` in the environment overrides it (development and testing).
    var databaseURLWithPassword: String {
        if let override = ProcessInfo.processInfo.environment["TIDEMARK_DATABASE_URL"], !override.isEmpty {
            return override
        }
        guard let password = Keychain.read(account: Keychain.databaseAccount), !password.isEmpty,
              var components = URLComponents(string: databaseURL) else { return databaseURL }
        components.password = password
        return components.string ?? databaseURL
    }

    /// Display form with the password masked: `postgres://tide:••••••••@127.0.0.1:5432/tidemark`.
    var databaseURLMasked: String {
        guard var components = URLComponents(string: databaseURL) else { return databaseURL }
        if Keychain.read(account: Keychain.databaseAccount)?.isEmpty == false { components.password = "••••••••" }
        return components.string?.removingPercentEncoding ?? databaseURL
    }

    private func set(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
