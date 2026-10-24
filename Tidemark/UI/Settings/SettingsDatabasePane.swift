import SwiftUI

/// Settings › Database: the PostgreSQL connection, the Macs sharing it, write batching, retention and schema.
struct SettingsDatabasePane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    @State private var urlDraft = ""
    @State private var passwordDraft = ""
    @State private var hasStoredPassword = false
    @State private var nameDraft = ""
    @State private var testing = false
    @State private var testResult: Result<String, Error>?
    @State private var tables: [String] = []
    @State private var schemaVersion: Int?

    var body: some View {
        Form {
            connectionSection
            macsSection
            writingSection
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 640)
        .onAppear(perform: load)
        .onChange(of: model.devices.thisDevice?.name) { _, name in
            if nameDraft.isEmpty, let name { nameDraft = name }
        }
        .task(id: model.live.database) { await loadSchema() }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            LabeledContent(tr("URL", "Settings")) {
                TextField(text: $urlDraft, prompt: Text(verbatim: "postgresql://user@127.0.0.1:5432/tidemark")) {
                    Text(tr("URL", "Settings"))
                }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(Theme.mono(12))
                .autocorrectionDisabled()
                .onSubmit(testConnection)
            }
            SecureField(text: $passwordDraft, prompt: Text(hasStoredPassword ? tr("Saved in the Keychain", "Settings") : tr("Optional", "Settings"))) {
                Text(tr("Password", "Settings"))
            }
            .onSubmit(testConnection)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                connectionStatus
                Spacer(minLength: 8)
                Button(tr("Test Connection", "Settings"), action: testConnection)
                    .disabled(testing)
            }
        } header: {
            Text(tr("PostgreSQL connection URL", "Settings"))
        } footer: {
            SettingsNote(text: tr("The password is kept in the Keychain, never in the URL.", "Settings"))
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
                SettingsStatusLine(tone: .failed, text: error.localizedDescription)
            }
        } else {
            switch model.live.database {
            case .connected(let detail):
                SettingsStatusLine(tone: .ok, text: connectedText(fallback: detail))
            case .connecting:
                SettingsStatusLine(tone: .pending, text: tr("Connecting…", "Settings"))
            case .failed(let message):
                SettingsStatusLine(tone: .failed, text: message)
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

    private var macsSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    ForEach(Array(sortedDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        SettingsDeviceRow(device: device, isThisMac: device.id == model.devices.thisDeviceID, now: context.date)
                    }
                    if sortedDevices.isEmpty {
                        Text(tr("No Mac has written to this database yet.", "Settings"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
            TextField(text: $nameDraft, prompt: Text(Self.computerName)) {
                Text(tr("Name this Mac", "Settings"))
            }
            .onSubmit(renameThisMac)
        } header: {
            Text(tr("Macs writing to this database", "Settings"))
        } footer: {
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

    private var writingSection: some View {
        Section {
            Picker(selection: batchBinding) {
                ForEach(batchOptions, id: \.self) { preset in
                    Text(SettingsDatabaseFormat.batchLabel(preset)).tag(preset)
                }
            } label: {
                Text(tr("Write in batches", "Settings"))
                Text(trf("Every %lld rows or %@ s, whichever comes first", "Settings", model.preferences.batchRows, SettingsDatabaseFormat.seconds(model.preferences.batchInterval)))
            }
            .pickerStyle(.menu)

            LabeledContent {
                Text(trf("%@ buffered", "Settings", Fmt.count(model.live.bufferedRows)))
                    .font(Theme.mono(11))
                    .foregroundStyle(model.live.bufferedRows > 0 ? Theme.amberInk : Theme.ink2)
                    .contentTransition(.numericText())
            } label: {
                Text(tr("If the database is unreachable", "Settings"))
                Text(trf("Buffer up to %@ rows on disk and replay them on reconnect", "Settings", Fmt.count(model.preferences.spoolLimit)))
            }

            Picker(selection: retentionBinding) {
                ForEach(retentionOptions, id: \.self) { days in
                    Text(SettingsDatabaseFormat.retentionLabel(days)).tag(days)
                }
            } label: {
                Text(tr("Keep requests", "Settings"))
                Text(tr("Older requests are deleted in batches every hour.", "Settings"))
            }
            .pickerStyle(.menu)

            LabeledContent {
                Text(schemaVersion.map { trf("schema v%lld", "Settings", $0) } ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
            } label: {
                Text(tr("Tables", "Settings"))
                Text(tables.isEmpty ? tr("Not connected", "Settings") : tables.joined(separator: " · "))
                    .font(Theme.mono(11))
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

    private var retentionOptions: [Int] {
        let current = model.preferences.retentionDays
        return SettingsDatabaseFormat.retentionPresets.contains(current)
            ? SettingsDatabaseFormat.retentionPresets
            : SettingsDatabaseFormat.retentionPresets + [current]
    }

    private var retentionBinding: Binding<Int> {
        Binding(get: { model.preferences.retentionDays }, set: { model.preferences.retentionDays = $0 })
    }

    // MARK: Actions

    private func load() {
        urlDraft = model.preferences.databaseURL
        hasStoredPassword = Keychain.read(account: Keychain.databaseAccount)?.isEmpty == false
        nameDraft = model.devices.thisDevice?.name ?? ""
    }

    private func loadSchema() async {
        let database = model.database
        let names = (try? await database.tableNames()) ?? []
        let version = try? await database.schemaVersion()
        tables = names
        schemaVersion = version
    }

    /// Saves the URL (moving an embedded password to the Keychain) and the password draft.
    /// Returns `true` when anything changed.
    private func commitConnection() -> Bool {
        let parts = SettingsDatabaseURL.split(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        var changed = false
        if parts.url != model.preferences.databaseURL {
            model.preferences.databaseURL = parts.url
            changed = true
        }
        urlDraft = parts.url
        if let password = parts.password ?? (passwordDraft.isEmpty ? nil : passwordDraft) {
            Keychain.write(password, account: Keychain.databaseAccount)
            passwordDraft = ""
            hasStoredPassword = true
            changed = true
        }
        return changed
    }

    private func testConnection() {
        guard !testing else { return }
        let changed = commitConnection()
        testing = true
        testResult = nil
        Task { @MainActor in
            let result = await model.capture.testDatabaseConnection()
            testing = false
            testResult = result
            if changed, case .success = result { model.capture.reconnect() }
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
        .padding(.vertical, 6)
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
    /// Days to keep requests: 0 = forever.
    static let retentionPresets = [0, 365, 90, 30, 7]

    static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: tr("Forever", "Settings")
        case 365: tr("1 year", "Settings")
        default: trn("%lld day", "%lld days", days, "Settings")
        }
    }

    /// `200 · 1 s`
    static func batchLabel(_ preset: Preferences.BatchPreset) -> String {
        trf("%lld · %@ s", "Settings", preset.rows, seconds(preset.interval))
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

/// Splits a pasted PostgreSQL URL into the URL kept in preferences and the password kept in the Keychain.
enum SettingsDatabaseURL {
    static func split(_ raw: String) -> (url: String, password: String?) {
        guard var components = URLComponents(string: raw), let password = components.password else { return (raw, nil) }
        components.password = nil
        return (components.string ?? raw, password.removingPercentEncoding ?? password)
    }
}
