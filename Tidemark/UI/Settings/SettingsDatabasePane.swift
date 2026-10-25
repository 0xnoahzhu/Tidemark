import SwiftUI

/// Settings › Database: the PostgreSQL connection, the Macs sharing it, write batching and schema.
struct SettingsDatabasePane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    /// The URL field's text: the saved URL with a mask where the Keychain password goes.
    @State private var urlDraft = ""
    @State private var nameDraft = ""
    @State private var testing = false
    @State private var testResult: Result<String, Error>?
    @State private var tables: [String] = []
    @State private var schemaVersion: Int?

    var body: some View {
        SettingsPage {
            connectionGroup
            macsGroup
            writingCard
        }
        .onAppear(perform: load)
        .onChange(of: model.devices.thisDevice?.name) { _, name in
            if nameDraft.isEmpty, let name { nameDraft = name }
        }
        .task(id: model.live.database) { await loadSchema() }
    }

    // MARK: Connection

    /// One URL field, password included: what is typed there goes to the Keychain and comes back masked.
    private var connectionGroup: some View {
        SettingsGroup(title: tr("PostgreSQL connection URL", "Settings")) {
            TextField(text: $urlDraft, prompt: Text(verbatim: "postgres://user@127.0.0.1:5432/tidemark")) {
                Text(tr("PostgreSQL connection URL", "Settings"))
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .autocorrectionDisabled()
            .onSubmit(testConnection)
            .settingsField()
            HStack(spacing: 8) {
                connectionStatus
                Spacer(minLength: 8)
                Button(tr("Test Connection", "Settings"), action: testConnection)
                    .disabled(testing)
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if testing {
            SettingsStatusLine(tone: .pending, text: tr("Connecting…", "Settings"))
        } else if let testResult {
            switch testResult {
            case .success(let detail):
                SettingsStatusLine(tone: .ok, text: detail)
            case .failure(let error):
                SettingsStatusLine(tone: .failed, text: CaptureEngine.message(for: error))
            }
        } else {
            switch model.live.database {
            case .connected(let detail):
                SettingsStatusLine(tone: .ok, text: connectedText(fallback: detail))
            case .connecting:
                SettingsStatusLine(tone: .pending, text: tr("Connecting…", "Settings"))
            case .failed(let error):
                SettingsStatusLine(tone: .failed, text: CaptureEngine.message(for: error))
            case .paused:
                SettingsStatusLine(tone: .neutral, text: tr("Recording is paused", "Settings"))
            case .idle:
                SettingsStatusLine(tone: .neutral, text: tr("Not connected", "Settings"))
            }
        }
    }

    /// `Connected · PostgreSQL 18.3 · 2 ms`
    private func connectedText(fallback: String) -> String {
        let version = model.live.serverVersion
        guard !version.isEmpty else { return fallback.isEmpty ? tr("Connected", "Settings") : fallback }
        let roundTrip = model.live.lastRoundTrip.map { Fmt.ms(SettingsDatabaseFormat.milliseconds($0)) } ?? "—"
        return trf("Connected · PostgreSQL %@ · %@", "Settings", version, roundTrip)
    }

    // MARK: Macs

    private var macsGroup: some View {
        SettingsGroup(title: tr("Macs writing to this database", "Settings")) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SettingsCard {
                    ForEach(sortedDevices) { device in
                        SettingsDeviceRow(device: device, isThisMac: device.id == model.devices.thisDeviceID, now: context.date)
                    }
                    if sortedDevices.isEmpty {
                        Text(tr("No Mac has written to this database yet.", "Settings"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(tr("Name this Mac", "Settings"))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize()
                TextField(text: $nameDraft, prompt: Text(Self.computerName)) {
                    Text(tr("Name this Mac", "Settings"))
                }
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(renameThisMac)
                .settingsField(height: 26, cornerRadius: 7, padding: 9)
            }
            .font(.system(size: 12))
            SettingsNote(text: tr("Every row is tagged with the Mac it came from, so several Macs can share one database. Each Mac records and alerts on its own apps. Use the Mac menu at the top of the sidebar to look at one Mac's data.", "Settings"))
        }
    }

    /// This Mac's computer name, the placeholder for "Name this Mac".
    private static let computerName = Host.current().localizedName ?? "Mac"

    private var sortedDevices: [Device] {
        let me = model.devices.thisDeviceID
        return model.devices.devices.sorted { a, b in
            if (a.id == me) != (b.id == me) { return a.id == me }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Writing

    private var writingCard: some View {
        SettingsCard {
            SettingsRow(title: tr("Write in batches", "Settings"), note: SettingsDatabaseFormat.batchNote(model.preferences.batchPreset)) {
                Picker(tr("Write in batches", "Settings"), selection: batchBinding) {
                    ForEach(batchOptions, id: \.self) { preset in
                        Text(SettingsDatabaseFormat.batchLabel(preset)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: tr("If the database is unreachable", "Settings"),
                        note: trf("Buffer up to %@ rows on disk and replay them on reconnect", "Settings", Fmt.count(model.preferences.spoolLimit))) {
                Text(trf("%@ buffered", "Settings", Fmt.count(model.live.bufferedRows)))
                    .font(Theme.mono(11))
                    .foregroundStyle(model.live.bufferedRows > 0 ? Theme.amberInk : Theme.ink2)
                    .contentTransition(.numericText())
            }
            SettingsRow(title: tr("Tables", "Settings"),
                        note: tables.isEmpty ? tr("Not connected", "Settings") : tables.joined(separator: " · "),
                        noteFont: tables.isEmpty ? .system(size: 11) : Theme.mono(11)) {
                Text(schemaVersion.map { trf("schema v%lld", "Settings", $0) } ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private var batchOptions: [Preferences.BatchPreset] {
        let all = Preferences.BatchPreset.all
        let current = model.preferences.batchPreset
        return all.contains(current) ? all : all + [current]
    }

    private var batchBinding: Binding<Preferences.BatchPreset> {
        Binding(get: { model.preferences.batchPreset }, set: { model.preferences.batchPreset = $0 })
    }

    // MARK: Actions

    private func load() {
        urlDraft = SettingsDatabaseURL.masked(model.preferences.databaseURL, hasPassword: Self.hasStoredPassword)
        nameDraft = model.devices.thisDevice?.name ?? ""
    }

    private static var hasStoredPassword: Bool {
        Keychain.read(account: Keychain.databaseAccount)?.isEmpty == false
    }

    private func loadSchema() async {
        let database = model.database
        let names = (try? await database.tableNames()) ?? []
        let version = try? await database.schemaVersion()
        tables = names
        schemaVersion = version
    }

    /// Saves the URL field: the URL without its password to the preferences and the password to the Keychain
    /// (the mask keeps the saved one, a URL without a password removes it). Returns `true` when either changed.
    private func commitConnection() -> Bool {
        let parts = SettingsDatabaseURL.split(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        var changed = false
        if parts.url != model.preferences.databaseURL {
            model.preferences.databaseURL = parts.url
            changed = true
        }
        let stored = Keychain.read(account: Keychain.databaseAccount)
        switch parts.password {
        case .kept:
            break
        case .typed(let password):
            if password != stored {
                Keychain.write(password, account: Keychain.databaseAccount)
                changed = true
            }
        case .none:
            if stored?.isEmpty == false {
                Keychain.write(nil, account: Keychain.databaseAccount)
                changed = true
            }
        }
        urlDraft = SettingsDatabaseURL.masked(parts.url, hasPassword: Self.hasStoredPassword)
        return changed
    }

    /// Saves a changed URL or password, reconnects so the engine rebuilds its database client from the saved
    /// credentials, and only then tests: the test always runs against what was just saved.
    private func testConnection() {
        guard !testing else { return }
        if commitConnection() { model.capture.reconnect() }
        testing = true
        testResult = nil
        Task { @MainActor in
            let result = await model.capture.testDatabaseConnection()
            testing = false
            testResult = result
            await loadSchema()
        }
    }

    private func renameThisMac() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != model.devices.thisDevice?.name else { return }
        Task { await model.capture.renameThisMac(name) }
    }
}

/// One row of "Macs writing to this database".
private struct SettingsDeviceRow: View {
    var device: Device
    var isThisMac: Bool
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.deviceColor(hue: device.hue))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if isThisMac {
                        TagBadge(text: tr("This Mac", "Settings"), style: .accent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(activity.text)
                .font(.system(size: 11))
                .foregroundStyle(activity.online ? Color(oklch: 0.55, 0.13, 150) : Theme.ink3)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        let rows = trf("%@ rows", "Settings", Fmt.count(device.rowCount))
        guard let model = device.model, !model.isEmpty else { return rows }
        return model + " · " + rows
    }

    private var activity: (text: String, online: Bool) {
        switch device.activity(now: now) {
        case .writingNow: (tr("Writing now", "Settings"), true)
        case .lastWrite(let seconds): (trf("Last write %lld s ago", "Settings", seconds), true)
        case .offline(let hours): (trf("Offline · last write %lld h ago", "Settings", hours), false)
        case .never: (tr("No writes yet", "Settings"), false)
        }
    }
}

/// Formatting for the Database pane.
@MainActor
enum SettingsDatabaseFormat {
    /// `200 · 1 s`
    static func batchLabel(_ preset: Preferences.BatchPreset) -> String {
        trf("%lld · %@ s", "Settings", preset.rows, seconds(preset.interval))
    }

    /// `Every 200 rows or 1 second, whichever comes first`
    static func batchNote(_ preset: Preferences.BatchPreset) -> String {
        preset.interval == 1
            ? trf("Every %lld rows or 1 second, whichever comes first", "Settings", preset.rows)
            : trf("Every %lld rows or %@ seconds, whichever comes first", "Settings", preset.rows, seconds(preset.interval))
    }

    /// `1`, `0.5`
    nonisolated static func seconds(_ interval: Double) -> String {
        interval.rounded() == interval ? String(Int(interval)) : String(format: "%g", interval)
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}

/// The URL field's text and what it means for the URL kept in the preferences and the password kept in the
/// Keychain. The field shows the saved password as a mask: `postgres://tide:••••••••@127.0.0.1:5432/tidemark`.
enum SettingsDatabaseURL {
    /// What the field says about the Keychain password.
    enum Password: Equatable {
        /// The mask (or what is left of it): keep the saved password.
        case kept
        /// A password typed into the URL.
        case typed(String)
        /// A URL without a password: there is none.
        case none
    }

    static let mask = "••••••••"
    /// ASCII stand-in for the mask while `URLComponents` builds the string (it would percent-encode the dots).
    private static let placeholder = "TIDEMARKPASSWORD"

    /// The saved URL with the mask where the saved password goes.
    static func masked(_ url: String, hasPassword: Bool) -> String {
        guard hasPassword, var components = URLComponents(string: url), components.scheme != nil else { return url }
        components.password = placeholder
        guard let string = components.string, let range = string.range(of: ":\(placeholder)@") else { return url }
        return string.replacingCharacters(in: range, with: ":\(mask)@")
    }

    /// Splits the field's text into the URL to keep (without a password) and what happens to the password. Text
    /// that is not a URL keeps the saved password, so a typo never loses it.
    static func split(_ raw: String) -> (url: String, password: Password) {
        guard var components = URLComponents(string: raw), components.scheme != nil else { return (raw, .kept) }
        let password = components.password
        components.password = nil
        if components.user?.isEmpty == true { components.user = nil }
        let url = components.string ?? raw
        guard let password, !password.isEmpty else { return (url, .none) }
        return (url, password.allSatisfy { $0 == "•" } ? .kept : .typed(password))
    }
}
