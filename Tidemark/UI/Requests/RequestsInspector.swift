import SwiftUI

/// Inspector of the selected request, live or stored: process chain, connection, its journey through Surge, timing,
/// related records and storage.
struct RequestsInspector: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var close: () -> Void

    /// Tidemark's records about the request, loaded when it is shown.
    @State private var details: RequestsInspectorDetails?

    var body: some View {
        let identity = model.requestsIdentity(for: record)
        // Details of the request shown before stay out until this one's arrive.
        let details = details?.key == record.key ? details : nil
        VStack(spacing: 0) {
            RequestsInspectorHeader(record: record, close: close)
            Divider()
            // The stack sizes the scroll view only to share the height out; filling what it is offered, it does not
            // lay the whole request out for that.
            RequestsInspectorFill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18.px) {
                        RequestsInspectorChain(record: record, identity: identity)
                        RequestsInspectorConnection(record: record)
                        RequestsInspectorJourney(
                            journey: RequestsJourney(record: record, related: details?.related, nodeType: details?.nodeType, proxyGeo: details?.proxyGeo),
                            notes: record.notes
                        )
                        .equatable()
                        RequestsInspectorTiming(record: record)
                        RequestsInspectorRelated(record: record, details: details)
                        RequestsInspectorStored(record: record)
                    }
                    .padding(.horizontal, 16.px)
                    .padding(.vertical, 14.px)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
            }
            Divider()
            RequestsInspectorActions(record: record, identity: identity)
        }
        .task(id: RequestsInspectorDetails.Source(record)) {
            try? await Task.sleep(for: RequestsInspectorDetails.settleDelay)
            guard !Task.isCancelled else { return }
            await RequestsInspectorDetails.load(for: record, model: model) { loaded in
                if !Task.isCancelled { self.details = loaded }
            }
        }
    }
}

/// Takes the size it is offered and never measures its content for a size of its own: the inspector's size is its
/// column's, and its scroll view's the rest of the column.
///
/// A flexible frame still asks its content, so each time the selection moved, the hosting view's minimum size and the
/// stack sharing out the height laid every text of the request out again, beside the layout that draws it.
struct RequestsInspectorFill: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    // No alignment guides of its own either: by default a layout takes its content's, which it places to read them.

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        nil
    }
}

/// Method and status chips, host and URL, and the host's other requests.
private struct RequestsInspectorHeader: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6.px) {
            HStack(spacing: 6.px) {
                Text(record.method.uppercased())
                    .font(Theme.mono(10, weight: .bold))
                    .padding(.horizontal, 6.px)
                    .padding(.vertical, 2.px)
                    .background(Theme.fill, in: .rect(cornerRadius: 5.px, style: .continuous))
                    .foregroundStyle(Theme.ink2)
                if let status = RequestsPresentation.status(of: record) {
                    RequestsStatusChip(status: status)
                }
                if record.isNew {
                    TagBadge(text: tr("FIRST VISIT", "Requests"), style: .new)
                }
                Spacer(minLength: 4.px)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.design(11, .semibold))
                        .frame(width: 22.px, height: 22.px)
                        .contentShape(.rect(cornerRadius: 6.px))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.ink2)
                .keyboardShortcut(.cancelAction)
                .help(tr("Close", "Requests"))
                .accessibilityLabel(tr("Close", "Requests"))
            }
            // The design's 16 px / 650 host title, slightly tightened.
            Text(record.host)
                .font(.design(16, .semibold))
                .tracking(-0.16 * UIScale.factor)
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
            if !showsHostHistory {
                Button(tr("Requests to this host", "Requests")) {
                    model.nav.openRequests(forHost: record.host)
                }
                .buttonStyle(.link)
                .font(.design(11.5))
                .help(trf("Show every stored request to %@ in History", "Requests", record.host))
            }
        }
        .padding(.horizontal, 16.px)
        .padding(.top, 14.px)
        .padding(.bottom, 12.px)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// History already shows exactly this host's requests.
    private var showsHostHistory: Bool {
        let nav = model.nav
        return !nav.requestsLive && nav.history.host == RequestsHostFilter.normalized(record.host)
    }
}

/// `Tunnel` in green, `Failed` in red.
private struct RequestsStatusChip: View {
    var status: RequestsPresentation.Status

    var body: some View {
        let (label, colors): (String, (Color, Color)) = switch status {
        case .tunnel: (tr("Tunnel", "Requests"), Theme.tint(150))
        case .failed: (tr("Failed", "Requests"), Theme.tint(27))
        }
        Text(label)
            .font(.design(10.5, .semibold))
            .padding(.horizontal, 7.px)
            .padding(.vertical, 2.px)
            .background(colors.0, in: .rect(cornerRadius: 5.px, style: .continuous))
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
        VStack(alignment: .leading, spacing: 8.px) {
            SectionLabel(text: tr("Process chain", "Requests"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                    let isLeaf = index == links.count - 1
                    HStack(spacing: 6.px) {
                        if index > 0 {
                            Text(verbatim: "└")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.ink3)
                        }
                        Text(link.name.isEmpty ? RequestsPresentation.unknownProcessLabel : link.name)
                            .font(.design(12.5, isLeaf ? .semibold : .regular))
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
                            Spacer(minLength: 4.px)
                            TagBadge(text: tr("sent it", "Requests"), style: .accent)
                        }
                    }
                    .padding(.leading, CGFloat(index) * 16.px)
                    .frame(height: 26.px)
                    .help(link.path ?? (link.name.isEmpty ? RequestsPresentation.unknownProcessLabel : link.name))
                }
            }
            .padding(.horizontal, 10.px)
            .padding(.vertical, 5.px)
            .background(Theme.card, in: .rect(cornerRadius: 10.px, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))

            Text(attributionText)
                .font(.design(11.5))
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
        VStack(alignment: .leading, spacing: 8.px) {
            SectionLabel(text: tr("Connection", "Requests"))
            VStack(alignment: .leading, spacing: 5.px) {
                KeyValueRow(tr("Remote IP", "Requests"), record.remoteIP ?? record.remoteAddress ?? "—", mono: true, labelWidth: 70.px)
                KeyValueRow(tr("Network", "Requests"), networkText, labelWidth: 70.px)
                if record.policyPath.isEmpty {
                    KeyValueRow(tr("Policy", "Requests"), "—", labelWidth: 70.px)
                } else {
                    KeyValueRow(label: tr("Policy", "Requests"), labelWidth: 70.px) {
                        PolicyChip(policyPath: record.policyPath)
                    }
                }
                KeyValueRow(tr("Rule", "Requests"), record.rule ?? "—", mono: true, labelWidth: 70.px)
                KeyValueRow(tr("Local", "Requests"), record.localAddress ?? "—", mono: true, labelWidth: 70.px)
                KeyValueRow(tr("Mac", "Requests"), macText, labelWidth: 70.px)
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
        return VStack(alignment: .leading, spacing: 8.px) {
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
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink3)
            } else {
                TimingBar(phases: phases)
                if phases.contains(where: { $0.kind == .local }) {
                    Text(tr("In global proxy mode the request rode the proxy's open connection, so no connect on the network is timed.", "Requests"))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// STORED: "Row #1284162 in requests, written at 14:32:02.958".
private struct RequestsInspectorStored: View {
    var record: RequestRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6.px) {
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
            .font(.design(12))
            .foregroundStyle(Theme.ink2)
            .lineHeight(Theme.noteLineHeight)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Open Cursor" / "Monitor Spotify" and "Copy as JSON": the design's 28 px buttons on a fill, Monitor on the accent.
private struct RequestsInspectorActions: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var identity: AppIdentity

    var body: some View {
        HStack(spacing: 8.px) {
            if let appID = identity.appID {
                Button(trf("Open %@", "Requests", identity.name)) {
                    model.nav.open(.app(appID), tab: RequestsPresentation.openAppTab)
                }
                .buttonStyle(DesignButtonStyle())
            } else if let bundle = record.bundlePath, !bundle.isEmpty {
                Button(trf("Monitor %@", "Requests", identity.name)) {
                    model.nav.openAddApp(preselect: bundle)
                }
                .buttonStyle(DesignButtonStyle(kind: .accent, horizontalPadding: 12))
            }
            Button(tr("Copy as JSON", "Requests")) {
                RequestsPasteboard.copy(RequestsPresentation.json(for: record))
            }
            .buttonStyle(DesignButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16.px)
        .padding(.vertical, 12.px)
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
