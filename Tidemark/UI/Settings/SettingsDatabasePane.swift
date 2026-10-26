import SwiftUI

/// Settings › Database: the PostgreSQL connection, the Macs sharing it, write batching and schema.
struct SettingsDatabasePane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    /// The URL field's text: the saved URL with its password masked.
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

    /// One URL field, password included: it is saved as typed and comes back with the password masked.
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

    /// This Mac first, with its writes since the last refresh, then the others by name.
    private var sortedDevices: [Device] {
        let me = model.devices.thisDeviceID
        return model.devices.devices.map { model.devices.current($0) }.sorted { a, b in
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
        urlDraft = SettingsDatabaseURL.masked(model.preferences.databaseURL)
        nameDraft = model.devices.thisDevice?.name ?? ""
    }

    private func loadSchema() async {
        let database = model.database
        let names = (try? await database.tableNames()) ?? []
        let version = try? await database.schemaVersion()
        tables = names
        schemaVersion = version
    }

    /// Saves the URL field as typed, password included, to the preferences; the mask (or what is left of it)
    /// keeps the saved password. Returns `true` when the URL changed. Text that is not a PostgreSQL URL is not
    /// saved: it throws, and the saved URL stays.
    private func commitConnection() throws(SettingsDatabaseURL.NotAURL) -> Bool {
        let saved = model.preferences.databaseURL
        guard let url = SettingsDatabaseURL.unmasked(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines), saved: saved) else {
            throw SettingsDatabaseURL.NotAURL()
        }
        urlDraft = SettingsDatabaseURL.masked(url)
        guard url != saved else { return false }
        model.preferences.databaseURL = url
        return true
    }

    /// Saves a changed URL, reconnects so the engine rebuilds its database client from it, and only then tests:
    /// the test always runs against what was just saved. Text that is not a PostgreSQL URL fails here, in the
    /// status line, and the field keeps it for correcting.
    private func testConnection() {
        guard !testing else { return }
        do {
            if try commitConnection() { model.capture.reconnect() }
        } catch {
            testResult = .failure(error)
            return
        }
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

/// The URL field's text and the URL kept in the preferences, password included. The field shows each secret of
/// the saved URL as a mask, `postgres://tide:••••••••@127.0.0.1:5432/tidemark`: the password, in the user info and
/// in a libpq `password` parameter alike, and libpq's `sslpassword` (the client key's passphrase). A mask left in
/// place (or what is left of it) keeps the saved secret of its kind.
enum SettingsDatabaseURL {
    /// Field text that is not a `postgres://` or `postgresql://` URL. It is neither saved nor shown back, since
    /// it may hold a password.
    struct NotAURL: LocalizedError {
        let errorDescription: String?

        @MainActor init() {
            errorDescription = tr("Enter a URL that starts with postgres:// or postgresql://.", "Settings")
        }
    }

    static let mask = "••••••••"

    /// The secrets a URL may hold.
    private enum Secret {
        /// The PostgreSQL password, in the user info or a `password` parameter.
        case password
        /// libpq's `sslpassword` parameter, the passphrase of the client key.
        case sslPassword
    }

    /// The saved URL as the field shows it: every secret in it (user info password, `password` and `sslpassword`
    /// parameters) masked, and nothing else changed. Text that is not a PostgreSQL URL comes back unchanged;
    /// Settings never saves such text.
    static func masked(_ url: String) -> String {
        guard let components = postgresComponents(url), let string = components.string else { return url }
        var secrets = components.rangeOfQuery.map { query in
            string[query].split(separator: "&").compactMap { item -> Range<String.Index>? in
                guard let equals = item.firstIndex(of: "="), secret(named: item[..<equals]) != nil else { return nil }
                let value = item.index(after: equals)..<item.endIndex
                return value.isEmpty ? nil : value
            }
        } ?? []
        if let password = components.rangeOfPassword, !password.isEmpty { secrets.append(password) }
        guard !secrets.isEmpty else { return url }
        // Only those ranges change: the same text anywhere else in the URL stays as it is.
        var shown = ""
        var rest = string.startIndex
        for range in secrets.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            shown += string[rest..<range.lowerBound]
            shown += mask
            rest = range.upperBound
        }
        return shown + string[rest...]
    }

    /// The URL to save for the field's text: the text as typed, except that a mask (or what is left of it) stands
    /// for the saved secret of its kind, encoded as it was saved. For the password, that is the saved one in the
    /// same place (user info or `password` parameter) when there is one there, or else the other. A mask is dropped
    /// when there is no saved secret of its kind to stand for, or when the text holds a newly typed one (for the
    /// password, in either place): that one is to be used. The field left as `masked` showed it gives back the
    /// saved URL exactly. Nil for text that is not a PostgreSQL URL, which must not be saved.
    static func unmasked(_ text: String, saved: String) -> String? {
        guard var components = postgresComponents(text) else { return nil }
        guard text != masked(saved) else { return saved }
        let items = components.percentEncodedQueryItems ?? []
        var typed = Set(items.filter { isTyped(value(of: $0)) }.compactMap(secret(of:)))
        if components.password.map(isTyped) == true { typed.insert(.password) }

        // The saved secrets a mask may stand for, percent-encoded; the last non-empty parameter is the one that
        // counts, as in `PostgresConnectionURL`.
        let savedComponents = postgresComponents(saved)
        var savedParameters: [Secret: String] = [:]
        for item in savedComponents?.percentEncodedQueryItems ?? [] {
            if let kind = secret(of: item), !typed.contains(kind), let value = item.value, !value.isEmpty { savedParameters[kind] = value }
        }
        let savedUserPassword = typed.contains(.password) ? nil : savedComponents?.percentEncodedPassword.flatMap { $0.isEmpty ? nil : $0 }

        var restored = false
        if let password = components.password, isMask(password) {
            if let savedUserPassword {
                components.percentEncodedPassword = savedUserPassword
            } else {
                components.password = savedParameters[.password]?.removingPercentEncoding
            }
            if components.password == nil, components.user?.isEmpty == true { components.user = nil }
            restored = true
        }
        if items.contains(where: { secret(of: $0) != nil && isMask(value(of: $0)) }) {
            // The other parameters keep their encoding.
            let kept = items.compactMap { item -> URLQueryItem? in
                guard let kind = secret(of: item), isMask(value(of: item)) else { return item }
                let replacement = savedParameters[kind] ?? (kind == .password ? savedUserPassword : nil)?
                    .removingPercentEncoding?.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
                return replacement.map { URLQueryItem(name: item.name, value: $0) }
            }
            components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
            restored = true
        }
        guard restored else { return text }
        return components.string
    }

    /// Characters a query parameter's value keeps unencoded (`&`, `=` and `+` would change its meaning).
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))

    /// The components of a `postgres://` or `postgresql://` URL, the schemes `PostgresConnectionURL` accepts. The
    /// mask's dots are percent-encoded first: `URLComponents` would otherwise encode the rest of their component
    /// again, `%20` included.
    private static func postgresComponents(_ string: String) -> URLComponents? {
        guard let components = URLComponents(string: string.replacingOccurrences(of: "•", with: "%E2%80%A2")),
              let scheme = components.scheme?.lowercased(), scheme == "postgres" || scheme == "postgresql" else { return nil }
        return components
    }

    /// The secret a query parameter holds, if any, whatever the case and encoding of its name.
    private static func secret(of item: URLQueryItem) -> Secret? { secret(named: item.name) }

    private static func secret(named name: some StringProtocol) -> Secret? {
        switch (name.removingPercentEncoding ?? String(name)).lowercased() {
        case "password": .password
        case "sslpassword": .sslPassword
        default: nil
        }
    }

    /// A query parameter's value, decoded.
    private static func value(of item: URLQueryItem) -> String { item.value.map { $0.removingPercentEncoding ?? $0 } ?? "" }

    /// A mask, or what is left of one.
    private static func isMask(_ secret: String) -> Bool { !secret.isEmpty && secret.allSatisfy { $0 == "•" } }

    /// A secret typed into the field: neither empty nor (what is left of) a mask.
    private static func isTyped(_ secret: String) -> Bool { !secret.isEmpty && !isMask(secret) }
}
