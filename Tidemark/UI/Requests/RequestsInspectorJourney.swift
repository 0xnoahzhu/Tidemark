import SwiftUI

/// JOURNEY: what happened to the request, stage by stage, on a thin timeline in a card, with Surge's log of it under.
struct RequestsInspectorJourney: View {
    var record: RequestRecord
    var details: RequestsInspectorDetails?

    var body: some View {
        let journey = RequestsJourney(record: record, related: details?.related, nodeType: details?.nodeType, proxyGeo: details?.proxyGeo)
        VStack(alignment: .leading, spacing: 8.px) {
            SectionLabel(text: tr("Journey", "Requests"))
            if !journey.stages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(journey.stages.enumerated()), id: \.offset) { index, stage in
                        RequestsJourneyStageView(stage: stage, isLast: index == journey.stages.count - 1)
                    }
                }
                .padding(.horizontal, 10.px)
                .padding(.vertical, 9.px)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: 10.px, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            } else {
                Text(tr("Surge has not said anything about this request yet.", "Requests"))
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink3)
            }
            if !record.notes.isEmpty {
                RequestsSurgeLog(notes: record.notes)
            }
        }
    }
}

/// One stage: a dot on the timeline, its name and offset, and what is known about it.
private struct RequestsJourneyStageView: View {
    var stage: RequestsJourney.Stage
    var isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3.px) {
            HStack(alignment: .firstTextBaseline, spacing: 8.px) {
                Text(RequestsJourneyLabels.title(of: stage))
                    .font(.design(12, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4.px)
                if let offset = RequestsJourneyLabels.offset(of: stage) {
                    Text(RequestsJourney.offsetLabel(offset))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize()
                }
            }
            content
        }
        .padding(.leading, 16.px)
        .padding(.bottom, isLast ? 0 : 10.px)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            // The dot sits on the title's line; the line runs down to the next stage's dot.
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(width: 1)
                        .padding(.top, 12.px)
                }
                Circle()
                    .fill(isError ? Theme.failed : Theme.ink3)
                    .frame(width: 7.px, height: 7.px)
                    .padding(.top, 5.px)
            }
            .frame(width: 7.px)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .combine)
    }

    /// An ending with an error marks its dot.
    private var isError: Bool {
        if case .end(let end) = stage { return end.isError }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .entered(let entered): RequestsJourneyEntered(entered: entered)
        case .dns(let dns): RequestsJourneyDNS(dns: dns)
        case .rule(let rule): RequestsJourneyRule(rule: rule)
        case .route(let route): RequestsJourneyRoute(route: route)
        case .connection(let connection): RequestsJourneyConnection(connection: connection)
        case .end(let end): RequestsJourneyEnd(end: end)
        }
    }
}

/// A sentence under a stage.
private struct RequestsJourneyNote: View {
    var text: String
    var color: Color = Theme.ink2

    var body: some View {
        Text(text)
            .font(.design(11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `Label  value` under a stage: the label in the faint ink, the value selectable.
private struct RequestsJourneyFact: View {
    var label: String
    var value: String
    var mono = false
    var color: Color = Theme.ink
    /// Said after the value in the secondary ink (`· From Surge's cache`).
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6.px) {
            Text(label)
                .font(.design(11))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
            let valueText = Text(value).font(mono ? Theme.mono(11) : .design(11.5)).foregroundStyle(color)
            Group {
                if let detail {
                    Text("\(valueText)\(Text(verbatim: " · " + detail).foregroundStyle(Theme.ink2))")
                } else {
                    valueText
                }
            }
            .font(.design(11.5))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RequestsJourneyEntered: View {
    var entered: RequestsJourney.Entered

    var body: some View {
        if let entry = entered.entry {
            RequestsJourneyNote(text: RequestsJourneyLabels.entered(entry))
        }
        if let sni = entered.sni {
            RequestsJourneyFact(label: tr("SNI", "Requests"), value: sni, mono: true)
        }
    }
}

private struct RequestsJourneyDNS: View {
    var dns: RequestsJourney.DNS

    var body: some View {
        if let lookup = dns.lookup {
            RequestsJourneyNote(text: RequestsJourneyLabels.lookup(lookup, server: dns.answer?.server.map(RequestsJourney.serverLabel)))
                .help(dns.answer?.server ?? "")
        } else if let server = dns.answer?.server {
            RequestsJourneyFact(label: tr("Server", "Requests"), value: RequestsJourney.serverLabel(server))
                .help(server)
        }
        if !dns.cnames.isEmpty {
            RequestsJourneyFact(label: "CNAME", value: dns.cnames.joined(separator: " → "), mono: true)
        }
        if let answer = dns.answer, !answer.addresses.isEmpty {
            RequestsJourneyFact(label: tr("Answer", "Requests"), value: answer.addresses.joined(separator: ", "), mono: true)
        } else if let counts = dns.recordCounts {
            RequestsJourneyFact(label: tr("Answer", "Requests"), value: trf("%1$lld A, %2$lld AAAA", "Requests", counts.a, counts.aaaa))
        }
        if let matched = dns.matchedIP {
            RequestsJourneyFact(label: tr("Matched on", "Requests"), value: matched, mono: true)
        }
        if dns.resolvedByProxy {
            RequestsJourneyNote(text: tr("The proxy resolved the name on its side, which this Mac can't see.", "Requests"))
        }
        if let shown = dns.shownIP {
            RequestsJourneyFact(label: tr("IP shown", "Requests"), value: shown.ip, mono: true, detail: RequestsJourneyLabels.shownIPDetail(shown))
        }
    }
}

private struct RequestsJourneyRule: View {
    var rule: RequestsJourney.Rule

    var body: some View {
        switch rule.decision {
        case .matched(let matched):
            RequestsJourneyFact(label: tr("Matched", "Requests"), value: matched, mono: true)
        case .global(let policy):
            RequestsJourneyNote(text: trf("Global · %@", "Requests", policy), color: Theme.ink)
        case .allDirect:
            RequestsJourneyNote(text: tr("All direct", "Requests"), color: Theme.ink)
        }
        if let subRule = rule.subRule {
            RequestsJourneyFact(label: tr("Sub-rule", "Requests"), value: subRule, mono: true)
        }
        if let original = rule.originalPolicy {
            RequestsJourneyNote(text: trf("Surge first chose %@.", "Requests", original))
        }
    }
}

/// The hops as a short chain, each with its role, and what Surge cannot show.
private struct RequestsJourneyRoute: View {
    var route: RequestsJourney.Route

    var body: some View {
        VStack(alignment: .leading, spacing: 2.px) {
            ForEach(Array(route.hops.enumerated()), id: \.offset) { index, hop in
                let labels = RequestsJourneyLabels.hop(hop)
                let value = Text(labels.value)
                    .font(labels.mono ? Theme.mono(11) : .design(11.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                let role = Text(labels.role)
                    .font(.design(11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5.px) {
                    Text(verbatim: index == 0 ? "·" : "→")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 10.px, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        // The role follows the value on its line where both fit, and goes under it where not.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 6.px) {
                                value.fixedSize()
                                role.fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                value
                                role
                            }
                        }
                        if let detail = labels.detail {
                            Text(detail)
                                .font(.design(11))
                                .foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .help(labels.value)
            }
            Text(tr("Router-level hops aren't visible to Surge.", "Requests"))
                .font(.design(11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2.px)
        }
    }
}

private struct RequestsJourneyConnection: View {
    var connection: RequestsJourney.Connection

    var body: some View {
        if connection.reused {
            RequestsJourneyNote(text: tr("Reused an open connection", "Requests"))
            if let connector = connection.connector {
                RequestsJourneyFact(label: tr("Connector", "Requests"), value: connector, mono: true)
            }
        } else {
            RequestsJourneyNote(text: tr("Opened a new connection", "Requests"))
        }
    }
}

private struct RequestsJourneyEnd: View {
    var end: RequestsJourney.End

    var body: some View {
        if let reason = end.reason {
            RequestsJourneyNote(text: RequestsJourneyLabels.endReason(reason), color: end.isError ? Theme.failed : Theme.ink)
                .help(reason)
        } else if end.state == .failed {
            RequestsJourneyNote(text: tr("Surge marked it failed", "Requests"), color: Theme.failed)
        } else if end.state == .rejected {
            RequestsJourneyNote(text: tr("Surge rejected it", "Requests"), color: Theme.failed)
        }
        if let error = end.proxyError {
            RequestsJourneyFact(label: tr("Proxy error", "Requests"), value: error.error, color: Theme.failed)
                .help(trf("%1$@ reported it at %2$@", "Requests", error.policy, Fmt.clock(error.at)))
        }
        if let duration = end.duration {
            let lasted = trf("Lasted %@", "Requests", RequestsJourneyLabels.duration(duration))
            RequestsJourneyNote(text: lasted + " · ↓ " + Fmt.bytes(end.inBytes) + "  ↑ " + Fmt.bytes(end.outBytes))
        }
    }
}

/// `▸ Surge log (9 lines)` and Copy; opened, Surge's notes for the request in mono, selectable.
private struct RequestsSurgeLog: View {
    var notes: [String]
    /// Stays as the user left it from one request to the next.
    @SceneStorage("requests.surgeLogExpanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6.px) {
            HStack(spacing: 8.px) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5.px) {
                        Image(systemName: "chevron.right")
                            .font(.design(9, .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Theme.ink3)
                        Text(trn("Surge log (%lld line)", "Surge log (%lld lines)", notes.count, "Requests"))
                            .font(.design(11.5, .medium))
                            .foregroundStyle(Theme.ink2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? tr("Shown", "Requests") : tr("Hidden", "Requests"))
                Spacer(minLength: 4.px)
                Button(tr("Copy", "Requests")) {
                    RequestsPasteboard.copy(notes.joined(separator: "\n"))
                }
                .buttonStyle(.link)
                .font(.design(11.5))
                .help(tr("Copy Surge's log of this request", "Requests"))
            }
            if expanded {
                // One entry per note, its clock faint, so a note that wraps still reads as one.
                VStack(alignment: .leading, spacing: 4.px) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        let (clock, text) = Self.split(note)
                        Text("\(Text(clock).foregroundStyle(Theme.ink3))\(Text(text).foregroundStyle(Theme.ink2))")
                            .font(Theme.mono(10.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 9.px)
                .padding(.vertical, 7.px)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill, in: .rect(cornerRadius: 8.px, style: .continuous))
            }
        }
    }

    /// `12:07:22.102428 ` and the rest of a note; a note without Surge's clock is all text.
    private static func split(_ note: String) -> (clock: String, text: String) {
        guard RequestTiming.parse(note: note) != nil, let space = note.firstIndex(of: " ") else { return ("", note) }
        return (String(note[...space]), String(note[note.index(after: space)...]))
    }
}

// MARK: - Related

/// RELATED: Tidemark's other records about the request, each opening its page.
struct RequestsInspectorRelated: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var details: RequestsInspectorDetails?

    var body: some View {
        let related = details?.related
        let change = related?.egressChange
        if related?.alert != nil || related?.probeSession != nil || change != nil || details?.failure != nil {
            VStack(alignment: .leading, spacing: 6.px) {
                SectionLabel(text: tr("Related", "Requests"))
                if let alert = related?.alert {
                    link(systemImage: "bell", title: RequestsJourneyLabels.alert(alert), detail: tr("Notifications", "Requests")) {
                        model.nav.alertFilter = .all
                        model.nav.open(.notifications)
                    }
                }
                if let session = related?.probeSession {
                    link(systemImage: "safari", title: trf("Site probe of %@", "Requests", session.host),
                         detail: Fmt.monthDay(session.startedAt, locale: Localizer.shared.locale) + " " + Fmt.hm(session.startedAt)) {
                        model.probe.selectedID = session.id
                        model.nav.open(.probe)
                    }
                }
                if let change {
                    link(systemImage: "arrow.triangle.branch", title: trf("Exit IP changed to %@", "Requests", change.ip),
                         detail: RequestsJourneyLabels.relative(change.changedAt.timeIntervalSince(record.startedAt))) {
                        model.nav.open(.egress)
                    }
                    .help(change.reason)
                }
                if let failure = details?.failure {
                    Text(tr("Couldn't load related records", "Requests"))
                        .font(.design(11.5))
                        .foregroundStyle(Theme.ink3)
                        .help(CaptureEngine.message(for: failure))
                }
            }
        }
    }

    /// The record as a link to its page, what else tells about it under it.
    private func link(systemImage: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6.px) {
            Image(systemName: systemImage)
                .font(.design(11))
                .foregroundStyle(Theme.ink3)
                .frame(width: 14.px)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1.px) {
                Button(action: action) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .font(.design(12))
                .help(title)
                Text(detail)
                    .font(.design(11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Labels

/// The Journey's and Related's wording, in the UI language.
@MainActor
enum RequestsJourneyLabels {
    static func title(of stage: RequestsJourney.Stage) -> String {
        switch stage {
        case .entered: tr("Entered", "Requests")
        case .dns: tr("DNS", "Requests")
        case .rule: tr("Rule", "Requests")
        case .route: tr("Route", "Requests")
        case .connection: tr("Connection", "Requests")
        case .end: tr("Ended", "Requests")
        }
    }

    static func offset(of stage: RequestsJourney.Stage) -> TimeInterval? {
        switch stage {
        case .entered(let entered): entered.offset
        case .dns(let dns): dns.offset
        case .rule(let rule): rule.offset
        case .route(let route): route.offset
        case .connection(let connection): connection.offset
        case .end(let end): end.offset
        }
    }

    /// How the request reached Surge.
    static func entered(_ entry: RequestEntry) -> String {
        switch entry {
        case .virtualInterface(udp: false): tr("Through Surge's virtual interface (VIF)", "Requests")
        case .virtualInterface(udp: true): tr("Through Surge's virtual interface (VIF), as UDP", "Requests")
        case .httpProxy: tr("Through Surge's HTTP proxy", "Requests")
        case .other(let mode): trf("Through Surge (takeover mode %lld)", "Requests", mode)
        }
    }

    /// `Looked up in 318 ms via cloudflare-dns.com`, `Answered from Surge's cache`.
    static func lookup(_ lookup: RequestsJourney.DNS.Lookup, server: String?) -> String {
        switch lookup {
        case .cached:
            return tr("Answered from Surge's cache", "Requests")
        case .lookedUp(let milliseconds):
            let time = milliseconds.map { Fmt.ms($0) }
            return switch (time, server) {
            case (let time?, let server?): trf("Looked up in %1$@ via %2$@", "Requests", time, server)
            case (let time?, nil): trf("Looked up in %@", "Requests", time)
            case (nil, let server?): trf("Looked up via %@", "Requests", server)
            case (nil, nil): tr("Looked up", "Requests")
            }
        }
    }

    /// Where the remote IP shown came from.
    static func source(_ source: RemoteIPSource) -> String {
        switch source {
        case .literal: tr("The host is this IP address", "Requests")
        case .surge: tr("Address Surge connected to", "Requests")
        case .ruleDNS: tr("Address Surge matched rules on", "Requests")
        case .tidemarkLookup: tr("Looked up by Tidemark", "Requests")
        case .surgeCache: tr("From Surge's cache", "Requests")
        }
    }

    /// `Looked up by Tidemark, 3 min before the request`: the source, and for an address resolved apart from the
    /// request, when.
    static func shownIPDetail(_ shown: RequestsJourney.ShownIP) -> String? {
        guard let source = shown.source else { return nil }
        let label = Self.source(source)
        guard source == .tidemarkLookup || source == .surgeCache, let age = shown.age else { return label }
        return trf("%1$@, %2$@", "Requests", label, relative(age))
    }

    /// `3 min before the request`, `as the request started`, `2 s after the request started`.
    static func relative(_ seconds: TimeInterval) -> String {
        if abs(seconds) < 1 { return tr("as the request started", "Requests") }
        let span = duration(abs(seconds))
        return seconds < 0 ? trf("%@ before the request", "Requests", span) : trf("%@ after the request started", "Requests", span)
    }

    /// `45 s`, `3 min`, `2 h`, `4 d`; under a second, `0.42 s`.
    static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: String(format: "%.2f s", seconds)
        case ..<10: String(format: "%.1f s", seconds)
        case ..<60: trf("%lld s", "Requests", Int(seconds))
        case ..<3600: trf("%lld min", "Requests", Int(seconds / 60))
        case ..<86400: trf("%lld h", "Requests", Int(seconds / 3600))
        default: trf("%lld d", "Requests", Int(seconds / 86400))
        }
    }

    /// An end reason in the UI language; wording Tidemark does not know reads as Surge wrote it.
    static func endReason(_ reason: String) -> String {
        switch RequestsJourney.EndKind(reason) {
        case .closedByRemote: tr("Closed by the server", "Requests")
        case .closedByClient: tr("Closed by the app", "Requests")
        case .closed: tr("Connection closed", "Requests")
        case .idle: tr("Closed after a while without traffic", "Requests")
        case .reset: tr("Connection reset", "Requests")
        case .brokenPipe: tr("Broken pipe", "Requests")
        case .unreachable: tr("Destination unreachable (ICMP)", "Requests")
        case .other(let words): words
        }
    }

    /// A hop's value, its role and what else is known about it.
    static func hop(_ hop: RequestsJourney.Hop) -> (value: String, mono: Bool, role: String, detail: String?) {
        switch hop {
        case .entry(let entry):
            let value = switch entry {
            case .virtualInterface(udp: false): "VIF"
            case .virtualInterface(udp: true): "VIF · UDP"
            case .httpProxy: tr("HTTP proxy", "Requests")
            case .other(let mode): "#\(mode)"
            }
            return (value, false, tr("entry", "Requests"), nil)
        case .group(let name):
            return (name, false, tr("policy group", "Requests"), nil)
        case .node(let name, let type):
            return (name, false, type.map { trf("node · %@", "Requests", $0) } ?? tr("node", "Requests"), nil)
        case .direct:
            return ("DIRECT", false, tr("from this Mac", "Requests"), nil)
        case .reject(let name):
            return (name, false, tr("rejected", "Requests"), nil)
        case .proxyServer(let ip, let geo):
            let network = geo?.display ?? ""
            return (ip, true, tr("proxy server", "Requests"), network.isEmpty ? nil : network)
        case .exit(let ip, let location, let age):
            let place = location.flatMap { $0.isEmpty ? nil : $0 }
            return (ip, true, tr("exit IP", "Requests"), [place, relative(age)].compactMap { $0 }.joined(separator: " · "))
        case .destination(let target, let address):
            return (target, false, tr("destination", "Requests"), address.map { trf("Connected to %@", "Requests", $0) })
        }
    }

    /// `New site linear.app`, `New host api.linear.app`, `New IP 104.18.36.12`.
    static func alert(_ alert: AlertItem) -> String {
        switch alert.scope {
        case .site: trf("New site %@", "Requests", alert.site ?? alert.value)
        case .host: trf("New host %@", "Requests", alert.value)
        case .ip: trf("New IP %@", "Requests", alert.value)
        }
    }
}
