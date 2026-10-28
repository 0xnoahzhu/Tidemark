import SwiftUI

/// Egress IP page: current egress, per-policy egress, change log, IP lookup and this Mac's network.
struct EgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let egress = model.egress
        ScrollView {
            EgressPageLayout(layout: .current) {
                VStack(spacing: EgressLayout.current.gap) {
                    EgressCurrentCard(sample: egress.current, lastChecked: egress.lastChecked, proxyMode: egress.proxyMode,
                                      currentRule: egress.currentRule, isChecking: egress.isChecking)
                    EgressPolicyCard(samples: Self.ordered(egress.samples), isChecking: egress.isChecking)
                    EgressChangesCard(changes: egress.changes)
                }
                EgressLookupCard(current: egress.current)
                EgressThisMacCard(network: egress.network)
            }
            .padding(.horizontal, EgressLayout.current.padding)
            .padding(.top, 18.px)
            .padding(.bottom, 22.px)
        }
        // Cards scroll out under the toolbar's hard edge, as on the other pages, not visibly under the title.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.bg3)
        .pageToolbar(tr("Egress IP", "Egress"), subtitle: tr("What the outside world sees, for each policy", "Egress")) {
            ToolbarItem(placement: .primaryAction) {
                Button(egress.isChecking ? tr("Checking…", "Egress") : tr("Check All", "Egress")) {
                    Task { await model.egressActions.checkAll() }
                }
                .disabled(egress.isChecking)
                .help(tr("Look up the egress IP through every policy again", "Egress"))
            }
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
        case "Profile reloaded": return tr("Profile reloaded", "Egress")
        case "Egress changed": return tr("Egress changed", "Egress")
        default:
            // `Network changed to Wi-Fi “Office-5G”`, `… to Ethernet`, `… to Cellular`
            let prefix = "Network changed to "
            guard reason.hasPrefix(prefix) else { return reason }
            return trf("Network changed to %@", "Egress", EgressFormat.interface(String(reason.dropFirst(prefix.count))))
        }
    }
}

/// Shared look of the Egress page cards (white, 14 px corners, hairline).
private struct EgressCard<Content: View>: View {
    var padding = EdgeInsets(top: 4.px, leading: 0, bottom: 4.px, trailing: 0)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14.px, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1.px, y: 1.px)
    }
}

// MARK: - Current egress

private struct EgressCurrentCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var sample: EgressSample?
    var lastChecked: Date?
    var proxyMode: Int?
    var currentRule: String?
    var isChecking: Bool

    var body: some View {
        EgressCard(padding: EdgeInsets(top: 18.px, leading: 20.px, bottom: 18.px, trailing: 20.px)) {
            VStack(alignment: .leading, spacing: 9.px) {
                HStack(spacing: 8.px) {
                    StatusDot(color: sample?.error == nil && sample != nil ? Theme.live : Theme.ink3, size: 7.px,
                              pulsing: isChecking && !reduceMotion)
                    Text(tr("Current egress", "Egress")).fontWeight(.semibold).foregroundStyle(Theme.ink)
                    if let mode = EgressFormat.modeLabel(proxyMode) { Text(mode) }
                    Spacer(minLength: 8.px)
                    if let lastChecked {
                        Text(trf("Checked %@", "Egress", Fmt.hms(lastChecked)))
                    }
                }
                .font(.design(11.5))
                .foregroundStyle(Theme.ink2)

                if let sample {
                    Text(sample.ip ?? "—")
                        .font(Theme.mono(34, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                        .contentTransition(.numericText())
                    let detail = EgressFormat.detail(sample)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.design(13))
                            .foregroundStyle(Theme.ink2)
                    }
                    HStack(spacing: 6.px) {
                        if !sample.policyPath.isEmpty {
                            EgressChip(text: sample.policyDisplay, colors: Theme.tint(Theme.policyHue(sample.policyPath)), weight: .medium)
                                .help(sample.policyDisplay)
                        }
                        if let rule = EgressFormat.ruleLabel(proxyMode: proxyMode, currentRule: currentRule) {
                            EgressChip(text: rule)
                        }
                        if let ipv6 = sample.hasIPv6 {
                            EgressChip(text: ipv6 ? tr("IPv6", "Egress") : tr("No IPv6", "Egress"))
                        }
                        if let latency = sample.latencyMs { EgressChip(text: Fmt.ms(Double(latency))) }
                        if let error = sample.error {
                            Text(EgressFormat.error(error))
                                .font(.design(11.5))
                                .foregroundStyle(Theme.failed)
                                .lineLimit(1)
                                .help(error)
                        }
                    }
                    .padding(.top, 2.px)
                } else {
                    Text(isChecking ? tr("Checking…", "Egress") : tr("Not checked yet", "Egress"))
                        .font(.design(22, .semibold))
                        .foregroundStyle(Theme.ink3)
                    Text(tr("Press Check All to look up the external IP through every policy.", "Egress"))
                        .font(.design(12.5))
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
    }
}

/// A chip of the current-egress card. The design draws the policy and the facts beside it alike, 11.5 px text in a
/// 6 px rounded rectangle, a little larger than the tables' policy chip: the facts on the fill, the policy in its
/// group's tint.
private struct EgressChip: View {
    var text: String
    var colors: (background: Color, foreground: Color) = (Theme.fill, Theme.ink2)
    var weight: Font.Weight = .regular

    var body: some View {
        Text(text)
            .font(.design(11.5, weight))
            .lineLimit(1)
            .padding(.horizontal, 8.px)
            .padding(.vertical, 2.px)
            .background(colors.background, in: RoundedRectangle(cornerRadius: 6.px, style: .continuous))
            .foregroundStyle(colors.foreground)
            .fixedSize()
    }
}

// MARK: - By policy

private struct EgressPolicyCard: View {
    var samples: [EgressSample]
    var isChecking: Bool

    private static let columns = EgressLayout.current.policyColumns

    var body: some View {
        EgressCard {
            HStack(alignment: .firstTextBaseline, spacing: 8.px) {
                Text(tr("By policy", "Egress")).font(.design(13, .semibold))
                Text(tr("The lookup goes out through each policy in turn", "Egress"))
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16.px)
            .padding(.top, 12.px)
            .padding(.bottom, 8.px)

            AnalyzeColumnsLayout(columns: Self.columns, spacing: EgressLayout.current.columnSpacing) {
                Text(tr("Policy", "Egress"))
                Text(tr("Egress IP", "Egress"))
                Text(tr("Location", "Egress"))
                Text(tr("Network", "Egress"))
                Text(tr("Latency", "Egress")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.design(11, .semibold))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 16.px)
            .frame(height: 26.px)

            if samples.isEmpty {
                Text(isChecking ? tr("Checking…", "Egress") : tr("No policies checked yet.", "Egress"))
                    .font(.design(12))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16.px)
                    .frame(maxWidth: .infinity, minHeight: 44.px, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
            }
            ForEach(samples) { sample in
                row(sample)
            }
        }
    }

    private func row(_ sample: EgressSample) -> some View {
        let network = [sample.network, EgressFormat.networkType(sample.networkType)].compactMap { $0 }.filter { !$0.isEmpty }
        return AnalyzeColumnsLayout(columns: Self.columns, spacing: EgressLayout.current.columnSpacing) {
            PolicyChip(policyPath: sample.policyPath, maxWidth: .infinity)
            HStack(spacing: 6.px) {
                Text(sample.ip ?? "—").font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle).layoutPriority(1).textSelection(.enabled)
                if sample.isCurrent {
                    Text(tr("NOW", "Egress"))
                        .font(.design(9, .bold))
                        .tracking(0.45 * UIScale.factor)
                        .foregroundStyle(Theme.accentInk)
                        .fixedSize()
                }
            }
            Text(EgressFormat.location(sample.location) ?? "—").foregroundStyle(Theme.ink2).lineLimit(1)
            Group {
                if let error = sample.error {
                    Text(EgressFormat.error(error)).foregroundStyle(Theme.failed)
                } else {
                    Text(sample.network ?? "—").foregroundStyle(Theme.ink2)
                }
            }
            .lineLimit(1)
            .help(sample.error ?? network.joined(separator: " · "))
            // A plain String, as the current egress's chip shows it: a localized key would group `9,999 ms`.
            Text(isChecking ? "…" : sample.latencyMs.map { Fmt.ms(Double($0)) } ?? "—")
                .font(Theme.mono(11))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .padding(.horizontal, 16.px)
        .frame(height: 34.px)
        .background(sample.isCurrent ? Theme.fresh : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

// MARK: - Changes

private struct EgressChangesCard: View {
    var changes: [EgressChange]

    private static let columns = EgressLayout.current.changesColumns

    var body: some View {
        EgressCard {
            Text(tr("Changes", "Egress"))
                .font(.design(13, .semibold))
                .padding(.horizontal, 16.px)
                .padding(.top, 12.px)
                .padding(.bottom, 8.px)
            if changes.isEmpty {
                Text(tr("No changes recorded yet. A new current egress IP is logged here with its likely cause.", "Egress"))
                    .font(.design(12))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16.px)
                    .padding(.vertical, 12.px)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
            }
            // Up to 50 changes: only the rows scrolled into view are built.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(changes) { change in
                    AnalyzeColumnsLayout(columns: Self.columns, spacing: EgressLayout.current.columnSpacing) {
                        Text(AnalyzeFormat.seen(change.changedAt, timeOnlyToday: true)).foregroundStyle(Theme.ink2).lineLimit(1)
                        Text(change.ip).font(Theme.mono(11.5)).lineLimit(1).textSelection(.enabled)
                        PolicyChip(policyPath: change.policyPath, maxWidth: .infinity)
                        Text(EgressView.localizedReason(change.reason)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    .font(.design(12))
                    .padding(.horizontal, 16.px)
                    .frame(height: 32.px)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                }
            }
        }
    }
}

// MARK: - Look up an IP

private struct EgressLookupCard: View {
    @Environment(AppModel.self) private var model
    /// The current egress: its IP is the field's placeholder and is looked up when nothing was typed.
    var current: EgressSample?

    @State private var query = ""
    @State private var result: IPLookupResult?
    @State private var isLookingUp = false

    private var suggestion: String? { current?.ip }

    var body: some View {
        EgressCard(padding: EdgeInsets(top: 14.px, leading: 16.px, bottom: 14.px, trailing: 16.px)) {
            VStack(alignment: .leading, spacing: 10.px) {
                Text(tr("Look up an IP", "Egress")).font(.design(13, .semibold))
                // The design's 28 px field and button.
                HStack(spacing: 6.px) {
                    TextField(text: $query, prompt: Text(verbatim: suggestion ?? "1.1.1.1")) {
                        Text(tr("IP address", "Egress"))
                    }
                    .font(Theme.mono(12))
                    .autocorrectionDisabled()
                    .onSubmit(lookUp)
                    .designField(horizontalPadding: 10)
                    Button(tr("Look Up", "Egress"), action: lookUp)
                        .buttonStyle(DesignButtonStyle(kind: .accent, horizontalPadding: 12))
                        .disabled(address.isEmpty || isLookingUp)
                }
                VStack(alignment: .leading, spacing: 7.px) {
                    KeyValueRow(tr("Country", "Egress"), EgressFormat.location(result?.country) ?? "—", labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow("ASN", result?.asn.map { "AS\($0)" } ?? "—", mono: true, labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow(tr("Organization", "Egress"), result?.organization ?? "—", labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow(tr("Type", "Egress"), EgressFormat.type(result?.networkType) ?? "—", labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow(tr("Reverse DNS", "Egress"), result?.reverseDNS ?? "—", mono: true, labelWidth: EgressLayout.current.labelWidth)
                }
                .redacted(reason: isLookingUp ? .placeholder : [])
                Text(EgressFormat.sourcesNote)
                    .font(.design(11))
                    .foregroundStyle(Theme.ink3)
                    // The design's `line-height: 1.45` for this note.
                    .lineHeight(.multiple(factor: 1.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Until something is typed, the card describes the current egress IP: what the last check knows
        // right away, then a full lookup (once per IP while the app runs); the egress monitor sends the
        // egress IP to the IP info service anyway.
        .task(id: suggestion) {
            guard query.trimmingCharacters(in: .whitespaces).isEmpty, let current, let ip = current.ip,
                  result?.ip != ip else { return }
            if let known = EgressLookupMemory.last, known.ip == ip {
                result = known
                return
            }
            result = EgressFormat.lookupSeed(from: current)
            lookUp()
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
            let found = await model.egressActions.lookup(ip: ip)
            result = found
            EgressLookupMemory.last = found
            isLookingUp = false
        }
    }
}

/// The last lookup, so revisiting the page doesn't ask the IP info service about the same IP again.
@MainActor
private enum EgressLookupMemory {
    static var last: IPLookupResult?
}

// MARK: - This Mac

private struct EgressThisMacCard: View {
    var network: ThisMacNetwork?

    var body: some View {
        EgressCard(padding: EdgeInsets(top: 14.px, leading: 16.px, bottom: 14.px, trailing: 16.px)) {
            VStack(alignment: .leading, spacing: 9.px) {
                Text(tr("This Mac", "Egress")).font(.design(13, .semibold))
                VStack(alignment: .leading, spacing: 7.px) {
                    KeyValueRow(tr("Interface", "Egress"), interface, labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow(tr("Local IP", "Egress"), network?.localIP ?? "—", mono: true, labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow(tr("Router", "Egress"), network?.router ?? "—", mono: true, labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow("DNS", dns, mono: true, labelWidth: EgressLayout.current.labelWidth)
                    KeyValueRow("Surge", surgeMode, labelWidth: EgressLayout.current.labelWidth)
                }
            }
        }
    }

    private var interface: String {
        let parts = [network?.interface, network?.interfaceDetail.map(EgressFormat.interface)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var dns: String {
        guard let servers = network?.dnsServers, !servers.isEmpty else { return "—" }
        return servers.joined(separator: " · ")
    }

    private var surgeMode: String {
        guard let mode = network?.surgeMode, !mode.isEmpty else { return "—" }
        return EgressFormat.surgeMode(mode)
    }
}

// MARK: - Layout

/// The Egress page's widths at a UI scale. The tables' fixed columns and minimums fit the text they hold: text grows
/// with the scale, and SF a little less than its size, so widths in design px fit it at every factor.
struct EgressLayout: Equatable {
    /// The layout at the app's factor.
    static let current = EgressLayout()

    /// The page's padding at either side.
    var padding: CGFloat
    /// Between the cards.
    var gap: CGFloat
    /// The lookup and This Mac column.
    var sideWidth: CGFloat
    /// A table's padding at either side, within its card.
    var tablePadding: CGFloat
    /// Between the columns of By policy and Changes.
    var columnSpacing: CGFloat
    /// The label column of the lookup and This Mac cards, as the inspector's: `Reverse DNS` and `Organization` in 12 px
    /// on one line.
    var labelWidth: CGFloat
    /// By policy: Policy takes room before Location (which holds a country name) and stops at 200 px, so chips such as
    /// `AI › AT&T-RackNerd-Hysteria2` are whole, as in the current-egress card. Egress IP holds the widest IPv4
    /// address in 11.5 px SF Mono with the NOW tag, and Latency `9999 ms` and its title.
    var policyColumns: [AnalyzeColumnsLayout.Column]
    /// Changes: the time (`Yesterday 23:59` at most), the IP in 11.5 px SF Mono, the policy and the reason.
    var changesColumns: [AnalyzeColumnsLayout.Column]

    init(factor: CGFloat = UIScale.factor) {
        func px(_ length: CGFloat) -> CGFloat { UIScale.length(length, factor: factor) }
        padding = px(20)
        gap = px(14)
        sideWidth = px(310)
        tablePadding = px(16)
        columnSpacing = px(12)
        labelWidth = px(84)
        policyColumns = [.flexible(weight: 1.3, min: px(128), max: px(200)), .fixed(px(150)), .flexible(weight: 1, min: px(70)),
                         .flexible(weight: 1.3, min: px(90)), .fixed(px(56))]
        changesColumns = [.fixed(px(110)), .fixed(px(128)), .flexible(weight: 1, min: px(128), max: px(200)), .flexible(weight: 1, min: px(100))]
    }

    /// The narrowest the left column gets: both tables at their columns' minimums.
    var tablesMinimum: CGFloat {
        max(policyColumns.minimumWidth(spacing: columnSpacing), changesColumns.minimumWidth(spacing: columnSpacing)) + 2 * tablePadding
    }

    /// Whether a page whose cards have `width` between the page's padding holds the tables beside the lookup and This
    /// Mac column.
    func showsSideColumn(width: CGFloat) -> Bool {
        width - gap - sideWidth >= tablesMinimum
    }
}

/// The page's two columns: the current egress, By policy and Changes (the first subview) on the left, and the lookup
/// and This Mac cards (the other two) in a column on the right. A page too narrow for the tables beside that column,
/// such as the minimum window's, puts the two cards side by side below the others. Either way they are the same
/// views, so what was typed into the lookup survives a resize.
private struct EgressPageLayout: Layout {
    var layout: EgressLayout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? layout.tablesMinimum + layout.gap + layout.sideWidth
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 3 else { return subviews.map { _ in .zero } }
        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let gap = layout.gap
        if layout.showsSideColumn(width: width) {
            let side = layout.sideWidth
            let main = CGRect(x: 0, y: 0, width: width - gap - side, height: height(0, width - gap - side))
            let lookup = CGRect(x: width - side, y: 0, width: side, height: height(1, side))
            return [main, lookup, CGRect(x: width - side, y: lookup.maxY + gap, width: side, height: height(2, side))]
        }
        let main = CGRect(x: 0, y: 0, width: width, height: height(0, width))
        let half = (width - gap) / 2
        return [main, CGRect(x: 0, y: main.maxY + gap, width: half, height: height(1, half)),
                CGRect(x: half + gap, y: main.maxY + gap, width: half, height: height(2, half))]
    }
}

// MARK: - Formatting

/// Display forms of the egress monitor's values, which are stored in English or as codes.
@MainActor
enum EgressFormat {
    /// `· rule mode`, `· global mode`, `· direct mode` for Surge's outbound mode (0 direct, 1 global, 2 rule).
    static func modeLabel(_ proxyMode: Int?) -> String? {
        switch proxyMode {
        case 0: tr("· direct mode", "Egress")
        case 1: tr("· global mode", "Egress")
        case 2: tr("· rule mode", "Egress")
        default: nil
        }
    }

    /// What sends traffic through the current policy: `Global proxy`, or `Rule FINAL` (the rule the monitor
    /// matched, FINAL when it did not report one) in rule mode.
    static func ruleLabel(proxyMode: Int?, currentRule: String?) -> String? {
        let rule = currentRule?.trimmingCharacters(in: .whitespaces) ?? ""
        switch proxyMode {
        case 0: return nil
        case 1: return tr("Global proxy", "Egress")
        default:
            if rule.hasPrefix("Global") { return tr("Global proxy", "Egress") }
            if !rule.isEmpty { return trf("Rule %@", "Egress", rule) }
            return proxyMode == 2 ? trf("Rule %@", "Egress", "FINAL") : nil
        }
    }

    /// `Hong Kong · AS9009 M247 Europe SRL · hosting network`
    static func detail(_ sample: EgressSample) -> String {
        [location(sample.location), sample.network, networkType(sample.networkType)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A country in the UI language: `US` → `United States` (or its Chinese name), `Los Angeles, US` → the
    /// Chinese country name, then the city, in Chinese, and English country names from older checks translated
    /// too. Anything else is shown as is.
    static func location(_ raw: String?, languageCode: String = Localizer.shared.languageCode) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let locale = Locale(identifier: languageCode)
        if let country = countryName(code: raw, locale: locale) { return country }
        let english = languageCode == "en"
        if let comma = raw.range(of: ", ", options: .backwards) {
            let city = String(raw[..<comma.lowerBound])
            if let country = countryName(code: String(raw[comma.upperBound...]), locale: locale) {
                return english ? raw : trf("%1$@, %2$@", "Egress", city, country)
            }
        }
        if !english, let code = englishCountryCodes[raw.lowercased()], let country = locale.localizedString(forRegionCode: code) {
            return country
        }
        return raw
    }

    /// `hosting` → `hosting network`, `Hosting · proxy` → `hosting network · proxy`.
    static func networkType(_ raw: String?) -> String? {
        let words = typeWords(raw)
        guard let first = words.first else { return nil }
        let head = networkWords[first.lowercased()].map { tr($0, "Egress") } ?? typeWord(first)
        return ([head] + words.dropFirst().map(typeWord)).joined(separator: " · ")
    }

    /// `Hosting · anycast` with each known word translated (the lookup's Type row).
    static func type(_ raw: String?) -> String? {
        let words = typeWords(raw)
        return words.isEmpty ? nil : words.map(typeWord).joined(separator: " · ")
    }

    /// `en0`'s kind: `Wired`, `Ethernet`, `Wi-Fi “Office-5G”` (the network name stays as is).
    static func interface(_ detail: String) -> String {
        if let quote = detail.firstIndex(of: "“") {
            let kind = detail[..<quote].trimmingCharacters(in: .whitespaces)
            return interfaceKind(kind) + " " + detail[quote...]
        }
        return interfaceKind(detail)
    }

    /// A check's stored error (English, as surge-cli and the timeout describe it) as a short text in the UI
    /// language; the full text is the help tag. Surge's own reason is kept in English when it is not a known one.
    static func error(_ raw: String, languageCode: String = Localizer.shared.languageCode) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = languageCode == "en"
        if let match = text.wholeMatch(of: /Timed out after (\d+) s\.?/), let seconds = Int(match.1) {
            return trf("Timed out after %lld s", "Egress", seconds)
        }
        if text.hasPrefix("surge-cli was not found") { return tr("surge-cli not found", "Egress") }
        if text.hasPrefix("Could not read the output of surge-cli") { return tr("Unreadable answer from surge-cli", "Egress") }
        if text.hasPrefix("surge-cli "), text.hasSuffix(" timed out.") { return tr("surge-cli did not answer in time", "Egress") }
        if text.hasPrefix("surge-cli "), let failed = text.range(of: " failed: ") {
            let message = text[failed.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let known = message.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if let key = surgeFailureKeys[known] { return tr(key, "Egress") }
            return english && !message.isEmpty ? message : tr("Surge couldn't check this policy", "Egress")
        }
        return english ? text : tr("The check failed", "Egress")
    }

    /// Surge's outbound-mode description (`SurgeOutputParser.surgeMode`), translated in the `SurgeCLI` table:
    /// as a whole (`Enhanced mode · rule-based`, `Enhanced mode` when Surge reports no outbound mode), else piece
    /// by piece, so a mode the table does not know keeps its known parts translated.
    static func surgeMode(_ mode: String) -> String {
        let whole = tr(mode, "SurgeCLI")
        guard whole == mode else { return whole }
        return mode.components(separatedBy: " · ").map { tr($0, "SurgeCLI") }.joined(separator: " · ")
    }

    /// Where the lookup's facts come from: the design's first sentence, then the IP info service (always on,
    /// with no setting to point at) and this Mac's resolver.
    static var sourcesNote: String {
        tr("Country and ASN come from Surge's own GeoIP database. Type comes from the IP info service, proxycheck.io, and reverse DNS from this Mac's resolver.", "Egress")
    }

    /// What the lookup card can show for the current egress before (or without) a lookup.
    static func lookupSeed(from sample: EgressSample) -> IPLookupResult? {
        guard let ip = sample.ip else { return nil }
        var result = IPLookupResult(ip: ip, country: sample.location, networkType: sample.networkType)
        // `AS9009 M247 Europe SRL`, as the monitor writes it.
        if let network = sample.network, let match = network.wholeMatch(of: /AS(\d+)(?:\s+(.+))?/) {
            result.asn = Int(match.1)
            result.organization = match.2.map(String.init)
        } else {
            result.organization = sample.network
        }
        return result
    }

    // MARK: Private

    private static func countryName(code: String, locale: Locale) -> String? {
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return locale.localizedString(forRegionCode: code.uppercased())
    }

    /// English country name (lowercased) → region code, for names stored by earlier versions.
    private static let englishCountryCodes: [String: String] = {
        var codes: [String: String] = [:]
        let english = [Locale(identifier: "en"), Locale(identifier: "en_US")]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter) else { continue }
            for locale in english {
                if let name = locale.localizedString(forRegionCode: code) { codes[name.lowercased()] = code }
            }
            if let name = EgressPlanner.countryName(code) { codes[name.lowercased()] = code }
        }
        return codes
    }()

    private static func typeWords(_ raw: String?) -> [String] {
        (raw ?? "").components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func typeWord(_ word: String) -> String {
        typeKeys[word.lowercased()].map { tr($0, "Egress") } ?? word
    }

    private static func interfaceKind(_ kind: String) -> String {
        let surge = tr(kind, "SurgeCLI")
        return surge != kind ? surge : (interfaceKeys[kind.lowercased()].map { tr($0, "Egress") } ?? kind)
    }

    /// Network types from the IP info service (proxycheck.io `type`, plus flags) and their display keys.
    private static let typeKeys: [String: String] = [
        "hosting": "Hosting", "residential": "Residential", "business": "Business", "wireless": "Wireless",
        "mobile": "Mobile", "education": "Education", "government": "Government",
        "proxy": "proxy", "vpn": "VPN", "anycast": "anycast",
    ]

    private static let networkWords: [String: String] = [
        "hosting": "hosting network", "residential": "residential network", "business": "business network",
        "wireless": "mobile network", "mobile": "mobile network", "education": "education network",
        "government": "government network",
    ]

    /// Reasons surge-cli gives for a failed check, lowercased without the final period.
    private static let surgeFailureKeys: [String: String] = [
        "http request timeout": "Timed out", "policy does not exist": "Policy not found",
        "no outgoing interface": "No outgoing interface",
    ]

    /// Interface kinds from `NWPathMonitor` that the `SurgeCLI` table does not have.
    private static let interfaceKeys: [String: String] = [
        "ethernet": "Ethernet", "cellular": "Cellular", "loopback": "Loopback", "offline": "offline",
    ]
}
