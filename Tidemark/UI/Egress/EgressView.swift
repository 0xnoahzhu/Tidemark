import SwiftUI

/// Egress IP page: current egress, per-policy egress, change log, IP lookup and this Mac's network.
struct EgressView: View {
    @Environment(AppModel.self) private var model

    /// Surge's outbound mode (0 direct, 1 global proxy, 2 rule), read from `environment`.
    @State private var proxyMode: Int?

    var body: some View {
        let egress = model.egress
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    EgressCurrentCard(sample: egress.current, lastChecked: egress.lastChecked, proxyMode: proxyMode,
                                      isChecking: egress.isChecking)
                    EgressPolicyCard(samples: Self.ordered(egress.samples), isChecking: egress.isChecking)
                    EgressChangesCard(changes: egress.changes)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    EgressLookupCard(suggestion: egress.current?.ip)
                    EgressThisMacCard(network: egress.network)
                }
                .frame(width: 310)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
        .background(Theme.bg3)
        .navigationTitle(tr("Egress IP", "Egress"))
        .navigationSubtitle(tr("What the outside world sees, for each policy", "Egress"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await model.egressActions.checkAll()
                        await refreshMode()
                    }
                } label: {
                    Label(egress.isChecking ? tr("Checking…", "Egress") : tr("Check All", "Egress"),
                          systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .symbolEffect(.rotate, isActive: egress.isChecking)
                }
                .disabled(egress.isChecking)
                .help(tr("Look up the egress IP through every policy again", "Egress"))
            }
        }
        .task { await refreshMode() }
    }

    private func refreshMode() async {
        if let environment = try? await model.surge.environment() {
            proxyMode = environment.proxyMode
        }
    }

    /// The current egress first, then the others as the monitor reported them.
    static func ordered(_ samples: [EgressSample]) -> [EgressSample] {
        samples.filter(\.isCurrent) + samples.filter { !$0.isCurrent }
    }

    /// Change reasons are stored in English; known ones are shown in the UI language.
    @MainActor
    static func localizedReason(_ reason: String) -> String {
        switch reason {
        case "Policy group switched by hand": return tr("Policy group switched by hand", "Egress")
        case "Auto test picked a faster node": return tr("Auto test picked a faster node", "Egress")
        case "Surge restarted": return tr("Surge restarted", "Egress")
        default:
            let wifi = "Network changed to Wi-Fi "
            if reason.hasPrefix(wifi) { return trf("Network changed to Wi-Fi %@", "Egress", String(reason.dropFirst(wifi.count))) }
            return reason
        }
    }
}

/// Shared look of the Egress page cards (white, 14 pt corners, hairline).
private struct EgressCard<Content: View>: View {
    var padding = EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

// MARK: - Current egress

private struct EgressCurrentCard: View {
    var sample: EgressSample?
    var lastChecked: Date?
    var proxyMode: Int?
    var isChecking: Bool

    var body: some View {
        EgressCard(padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    StatusDot(color: sample?.error == nil && sample != nil ? Theme.live : Theme.ink3, size: 7, pulsing: isChecking)
                    Text(tr("Current egress", "Egress")).fontWeight(.semibold).foregroundStyle(Theme.ink)
                    if let mode = modeLabel { Text(mode) }
                    Spacer(minLength: 8)
                    if let lastChecked {
                        Text(trf("Checked %@", "Egress", Fmt.hms(lastChecked)))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink2)

                if let sample {
                    Text(sample.ip ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                        .contentTransition(.numericText())
                    let detail = [sample.location, sample.network].compactMap { $0 }.filter { !$0.isEmpty }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                    }
                    HStack(spacing: 6) {
                        PolicyChip(policyPath: sample.policyPath)
                        if let rule = ruleLabel { AnalyzePill(text: rule, style: .neutral) }
                        if let latency = sample.latencyMs { AnalyzePill(text: "\(latency) ms", style: .neutral) }
                        if let error = sample.error {
                            Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.failed).lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text(isChecking ? tr("Checking…", "Egress") : tr("Not checked yet", "Egress"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                    Text(tr("Press Check All to look up the external IP through every policy.", "Egress"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    private var modeLabel: String? {
        switch proxyMode {
        case 0: tr("· direct mode", "Egress")
        case 1: tr("· global mode", "Egress")
        case 2: tr("· rule mode", "Egress")
        default: nil
        }
    }

    /// What sends traffic through the current policy: the FINAL rule in rule mode, the outbound mode otherwise.
    private var ruleLabel: String? {
        switch proxyMode {
        case 1: tr("Global proxy", "Egress")
        case 2: tr("Rule FINAL", "Egress")
        default: nil
        }
    }
}

// MARK: - By policy

private struct EgressPolicyCard: View {
    var samples: [EgressSample]
    var isChecking: Bool

    private static let columns: [AnalyzeColumnsLayout.Column] = [
        .fixed(128), .fixed(150), .flexible(weight: 1, min: 70), .flexible(weight: 1.3, min: 90), .fixed(56),
    ]

    var body: some View {
        EgressCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("By policy", "Egress")).font(.system(size: 13, weight: .semibold))
                Text(tr("The lookup goes out through each policy in turn", "Egress"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            AnalyzeColumnsLayout(columns: Self.columns, spacing: 12) {
                Text(tr("Policy", "Egress"))
                Text(tr("Egress IP", "Egress"))
                Text(tr("Location", "Egress"))
                Text(tr("Network", "Egress"))
                Text(tr("Latency", "Egress")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 16)
            .frame(height: 26)

            if samples.isEmpty {
                Text(isChecking ? tr("Checking…", "Egress") : tr("No policies checked yet.", "Egress"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
            }
            ForEach(samples) { sample in
                row(sample)
            }
        }
    }

    private func row(_ sample: EgressSample) -> some View {
        AnalyzeColumnsLayout(columns: Self.columns, spacing: 12) {
            AnalyzePolicyChip(policyPath: sample.policyPath, maxWidth: 128)
            HStack(spacing: 6) {
                Text(sample.ip ?? "—").font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle).layoutPriority(1).textSelection(.enabled)
                if sample.isCurrent {
                    Text(tr("NOW", "Egress"))
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.45)
                        .foregroundStyle(Theme.accentInk)
                        .fixedSize()
                }
            }
            Text(sample.location ?? "—").foregroundStyle(Theme.ink2).lineLimit(1)
            Group {
                if let error = sample.error {
                    Text(error).foregroundStyle(Theme.failed)
                } else {
                    Text(sample.network ?? "—").foregroundStyle(Theme.ink2)
                }
            }
            .lineLimit(1)
            .help(sample.error ?? sample.network ?? "")
            Text(isChecking ? "…" : sample.latencyMs.map { "\($0) ms" } ?? "—")
                .font(Theme.mono(11))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(sample.isCurrent ? Theme.fresh : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

// MARK: - Changes

private struct EgressChangesCard: View {
    var changes: [EgressChange]

    private static let columns: [AnalyzeColumnsLayout.Column] = [.fixed(110), .fixed(128), .fixed(128), .flexible(weight: 1, min: 100)]

    var body: some View {
        EgressCard {
            Text(tr("Changes", "Egress"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            if changes.isEmpty {
                Text(tr("No changes recorded yet. A new current egress IP is logged here with its likely cause.", "Egress"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
            }
            ForEach(changes) { change in
                AnalyzeColumnsLayout(columns: Self.columns, spacing: 12) {
                    Text(AnalyzeFormat.seen(change.changedAt, timeOnlyToday: true)).foregroundStyle(Theme.ink2).lineLimit(1)
                    Text(change.ip).font(Theme.mono(11.5)).lineLimit(1).textSelection(.enabled)
                    AnalyzePolicyChip(policyPath: change.policyPath, maxWidth: 128)
                    Text(EgressView.localizedReason(change.reason)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
            }
        }
    }
}

// MARK: - Look up an IP

private struct EgressLookupCard: View {
    @Environment(AppModel.self) private var model
    /// Placeholder address (the current egress IP).
    var suggestion: String?

    @State private var query = ""
    @State private var result: IPLookupResult?
    @State private var isLookingUp = false

    var body: some View {
        EgressCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Look up an IP", "Egress")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    TextField(text: $query, prompt: Text(verbatim: suggestion ?? "1.1.1.1")) {
                        Text(tr("IP address", "Egress"))
                    }
                    .textFieldStyle(.bordered)
                    .textInputBorderShape(.roundedRectangle)
                    .font(Theme.mono(12))
                    .autocorrectionDisabled()
                    .onSubmit(lookUp)
                    Button(tr("Look Up", "Egress"), action: lookUp)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .disabled(address.isEmpty || isLookingUp)
                }
                VStack(alignment: .leading, spacing: 7) {
                    KeyValueRow(tr("Country", "Egress"), result?.country ?? "—", labelWidth: 84)
                    KeyValueRow("ASN", result?.asn.map { "AS\($0)" } ?? "—", mono: true, labelWidth: 84)
                    KeyValueRow(tr("Organization", "Egress"), result?.organization ?? "—", labelWidth: 84)
                    KeyValueRow(tr("Type", "Egress"), result?.networkType ?? "—", labelWidth: 84)
                    KeyValueRow(tr("Reverse DNS", "Egress"), result?.reverseDNS ?? "—", mono: true, labelWidth: 84)
                }
                .redacted(reason: isLookingUp ? .placeholder : [])
                Text(tr("Country and ASN come from Surge's own GeoIP database. Type and reverse DNS come from the IP info service set in Settings.", "Egress"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var address: String {
        let typed = query.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (suggestion ?? "") : typed
    }

    private func lookUp() {
        let ip = address
        guard !ip.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        Task {
            result = await model.egressActions.lookup(ip: ip)
            isLookingUp = false
        }
    }
}

// MARK: - This Mac

private struct EgressThisMacCard: View {
    var network: ThisMacNetwork?

    var body: some View {
        EgressCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 9) {
                Text(tr("This Mac", "Egress")).font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 7) {
                    KeyValueRow(tr("Interface", "Egress"), interface, labelWidth: 84)
                    KeyValueRow(tr("Local IP", "Egress"), network?.localIP ?? "—", mono: true, labelWidth: 84)
                    KeyValueRow(tr("Router", "Egress"), network?.router ?? "—", mono: true, labelWidth: 84)
                    KeyValueRow("DNS", dns, mono: true, labelWidth: 84)
                    KeyValueRow("Surge", surgeMode, labelWidth: 84)
                }
            }
        }
    }

    private var interface: String {
        let parts = [network?.interface, network?.interfaceDetail].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var dns: String {
        guard let servers = network?.dnsServers, !servers.isEmpty else { return "—" }
        return servers.joined(separator: " · ")
    }

    private var surgeMode: String {
        guard let mode = network?.surgeMode, !mode.isEmpty else { return "—" }
        return mode == "Enhanced mode · rule-based" ? tr("Enhanced mode · rule-based", "Egress") : mode
    }
}
