import SwiftUI

/// Inspector of the selected request: process chain, connection, timing, host insight and storage.
struct RequestsInspector: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var close: () -> Void

    var body: some View {
        let identity = model.requestsIdentity(for: record)
        let appName = RequestsPresentation.isUnattributed(record, identity: identity) ? nil : identity.name
        VStack(spacing: 0) {
            RequestsInspectorHeader(record: record, close: close)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RequestsInspectorChain(record: record, identity: identity)
                    RequestsInspectorConnection(record: record)
                    RequestsInspectorTiming(record: record)
                    HostInsightView(context: RequestsPresentation.hostContext(for: record, appName: appName))
                    RequestsInspectorStored(record: record)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            Divider()
            RequestsInspectorActions(record: record, identity: identity)
        }
    }
}

/// Method and status chips, host and URL.
private struct RequestsInspectorHeader: View {
    var record: RequestRecord
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(record.method.uppercased())
                    .font(Theme.mono(10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.fill, in: .rect(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Theme.ink2)
                RequestsStatusChip(status: RequestsPresentation.status(of: record))
                if record.isNew {
                    TagBadge(text: tr("FIRST VISIT", "Requests"), style: .new)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.ink2)
                .keyboardShortcut(.cancelAction)
                .help(tr("Close", "Requests"))
                .accessibilityLabel(tr("Close", "Requests"))
            }
            // The design's 16 px / 650 host title, slightly tightened.
            Text(record.host)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.16)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let url = record.url, !url.isEmpty {
                Text(url)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Tunnel` / `Active` / `Completed` in green or accent, `Failed` / `Rejected` in red.
private struct RequestsStatusChip: View {
    var status: RequestsPresentation.Status

    var body: some View {
        let (label, colors): (String, (Color, Color)) = switch status {
        case .tunnel: (tr("Tunnel", "Requests"), Theme.tint(150))
        case .completed: (tr("Completed", "Requests"), Theme.tint(150))
        case .active: (tr("Active", "Requests"), (Theme.accentTint, Theme.accentInk))
        case .failed: (tr("Failed", "Requests"), Theme.tint(27))
        case .rejected: (tr("Rejected", "Requests"), Theme.tint(27))
        }
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colors.0, in: .rect(cornerRadius: 5, style: .continuous))
            .foregroundStyle(colors.1)
    }
}

/// PROCESS CHAIN card and the attribution sentence.
private struct RequestsInspectorChain: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var identity: AppIdentity

    var body: some View {
        let links = RequestsPresentation.chainLinks(for: record)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: tr("Process chain", "Requests"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                    let isLeaf = index == links.count - 1
                    HStack(spacing: 6) {
                        if index > 0 {
                            Text(verbatim: "└")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.ink3)
                        }
                        Text(link.name.isEmpty ? RequestsPresentation.unknownProcessLabel : link.name)
                            .font(.system(size: 12.5, weight: isLeaf ? .semibold : .regular))
                            .foregroundStyle(link.name.isEmpty ? Theme.ink2 : Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if link.pid > 0 {
                            Text(String(link.pid))
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.ink3)
                                .fixedSize()
                        }
                        if isLeaf {
                            Spacer(minLength: 4)
                            TagBadge(text: tr("sent it", "Requests"), style: .accent)
                        }
                    }
                    .padding(.leading, CGFloat(index) * 16)
                    .frame(height: 26)
                    .help(link.path ?? (link.name.isEmpty ? RequestsPresentation.unknownProcessLabel : link.name))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.card, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))

            Text(attributionText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attributionText: String {
        if RequestsPresentation.isUnattributed(record, identity: identity) {
            return tr("Surge reported no process for this request, so it only lands in the global log.", "Requests")
        }
        return switch RequestsPresentation.attribution(for: record, app: model.catalog.app(record.appID), displayName: identity.name) {
        case .rolledUp(let app, let parents):
            trn("Rolled up to %2$@ through %1$lld parent process", "Rolled up to %2$@ through %1$lld parent processes", parents, "Requests", app)
        case .direct(let app):
            trf("Matched %@ directly", "Requests", app)
        case .unmonitored(let app):
            trf("%@ is not monitored, so this only lands in the global log.", "Requests", app)
        }
    }
}

/// CONNECTION key / values.
private struct RequestsInspectorConnection: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: tr("Connection", "Requests"))
            VStack(alignment: .leading, spacing: 5) {
                KeyValueRow(tr("Remote IP", "Requests"), record.remoteIP ?? record.remoteAddress ?? "—", mono: true, labelWidth: 70)
                KeyValueRow(tr("Network", "Requests"), networkText, labelWidth: 70)
                if record.policyPath.isEmpty {
                    KeyValueRow(tr("Policy", "Requests"), "—", labelWidth: 70)
                } else {
                    KeyValueRow(label: tr("Policy", "Requests"), labelWidth: 70) {
                        PolicyChip(policyPath: record.policyPath)
                    }
                }
                KeyValueRow(tr("Rule", "Requests"), record.rule ?? "—", mono: true, labelWidth: 70)
                KeyValueRow(tr("Local", "Requests"), record.localAddress ?? "—", mono: true, labelWidth: 70)
                KeyValueRow(tr("Mac", "Requests"), macText, labelWidth: 70)
            }
        }
    }

    private var networkText: String {
        let display = record.geo?.display ?? ""
        return display.isEmpty ? "—" : display
    }

    private var macText: String {
        let devices = model.devices
        let name = devices.device(record.deviceID)?.name ?? devices.shortName(record.deviceID)
        return record.deviceID == devices.thisDeviceID ? trf("%@ (this Mac)", "Requests", name) : name
    }
}

/// TIMING: total and the phase bar; an active request's transfer phase keeps growing once a second.
private struct RequestsInspectorTiming: View {
    var record: RequestRecord

    var body: some View {
        if record.state == .active {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        } else {
            content(now: record.completedAt ?? record.startedAt)
        }
    }

    private func content(now: Date) -> some View {
        let phases = RequestTiming.phases(for: record, now: now)
        let total = phases.reduce(0) { $0 + $1.duration }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: tr("Timing", "Requests"))
                Spacer()
                Text(Fmt.ms(total * 1000))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink2)
                    .contentTransition(.numericText())
            }
            if phases.isEmpty {
                Text(tr("No timing yet", "Requests"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
            } else {
                TimingBar(phases: phases)
            }
        }
    }
}

/// STORED: "Row #1284162 in requests, written at 14:32:02.958".
private struct RequestsInspectorStored: View {
    var record: RequestRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: tr("Stored", "Requests"))
            Group {
                if let rowID = record.rowID {
                    RequestsStyledFormat.text(
                        tr("Row %1$@ in %2$@, written at %3$@", "Requests"),
                        arguments: ["#\(rowID)", "requests", Fmt.clock(record.writtenAt ?? record.startedAt)]
                    )
                } else {
                    Text(tr("Not written yet", "Requests"))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink2)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Open Cursor" / "Monitor Spotify" and "Copy as JSON".
private struct RequestsInspectorActions: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var identity: AppIdentity

    var body: some View {
        HStack(spacing: 8) {
            if let appID = identity.appID {
                Button(trf("Open %@", "Requests", identity.name)) {
                    model.nav.open(.app(appID), tab: RequestsPresentation.openAppTab)
                }
            } else if let bundle = record.bundlePath, !bundle.isEmpty {
                Button(trf("Monitor %@", "Requests", identity.name)) {
                    model.nav.openAddApp(preselect: bundle)
                }
                .buttonStyle(.borderedProminent)
            }
            Button(tr("Copy as JSON", "Requests")) {
                RequestsPasteboard.copy(RequestsPresentation.json(for: record))
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Fills a localized format with monospaced, full-ink arguments ("Row **#1284162** in **requests**…").
enum RequestsStyledFormat {
    /// `format` uses positional `%n$@` placeholders; each one is replaced by the matching argument.
    static func text(_ format: String, arguments: [String]) -> Text {
        var attributed = AttributedString()
        var rest = Substring(format)
        while let range = rest.range(of: #"%(\d+)\$@"#, options: .regularExpression) {
            attributed += AttributedString(String(rest[rest.startIndex..<range.lowerBound]))
            let digits = rest[range].dropFirst().prefix { $0.isNumber }
            if let index = Int(digits), index >= 1, index <= arguments.count {
                var argument = AttributedString(arguments[index - 1])
                argument.font = Theme.mono(11.5)
                argument.foregroundColor = Theme.ink
                attributed += argument
            }
            rest = rest[range.upperBound...]
        }
        attributed += AttributedString(String(rest))
        return Text(attributed)
    }
}
