import SwiftUI

/// Rows, steps and time axis of a probe's host waterfall (pure, so it can be tested).
struct ProbeWaterfallModel: Equatable {
    struct Row: Identifiable, Equatable {
        var host: String
        var ipCount: Int
        var requests: Int
        var firstAt: TimeInterval
        /// Bar start and width as fractions of the axis.
        var start: Double
        var width: Double
        /// Same registrable domain as the probed URL.
        var sameSite: Bool
        var id: String { host }
    }

    struct Step: Identifiable, Equatable {
        var index: Int
        var label: String
        var at: TimeInterval
        var rows: [Row]
        var id: Int { index }
    }

    /// Seconds covered by the time axis.
    var axis: TimeInterval
    var steps: [Step]
    /// Positions (fractions of the axis) of the steps after the first: the user's clicks.
    var marks: [Double]

    /// `max(12 s, the elapsed time plus 1.5 s rounded up to 4 s)`, like the design.
    static func axis(for elapsed: TimeInterval) -> TimeInterval {
        max(12, (max(0, elapsed + 1.5) / 4).rounded(.up) * 4)
    }

    init(session: ProbeSession, elapsed: TimeInterval, site: (String) -> String) {
        let axis = Self.axis(for: elapsed)
        self.axis = axis
        let probedSite = site(session.host)
        let sessionSteps = session.steps.isEmpty ? [ProbeStep(at: 0, label: "Page load", url: session.url)] : session.steps
        let lastStep = sessionSteps.count - 1

        var rowsByStep: [Int: [Row]] = [:]
        for host in session.hosts where host.firstAt <= elapsed {
            let end = min(max(host.lastAt, host.firstAt), elapsed)
            let row = Row(host: host.host, ipCount: host.ips.count, requests: host.requestCount, firstAt: host.firstAt,
                          start: host.firstAt / axis, width: max(0.006, (end - host.firstAt) / axis),
                          sameSite: site(host.host) == probedSite)
            rowsByStep[min(max(0, host.step), lastStep), default: []].append(row)
        }
        steps = sessionSteps.enumerated().map { index, step in
            Step(index: index, label: step.label, at: step.at,
                 rows: (rowsByStep[index] ?? []).sorted { $0.firstAt != $1.firstAt ? $0.firstAt < $1.firstAt : $0.host < $1.host })
        }
        marks = sessionSteps.dropFirst().map { min(1, $0.at / axis) }
    }

    /// Axis tick labels: `0s`, a quarter, half, three quarters and the full axis.
    var tickLabels: [String] {
        (0...4).map { String(format: "%.0fs", axis * Double($0) / 4) }
    }
}

/// Host waterfall of a probe: one row per host under the step that first reached it, with bars from
/// its first to its last activity (accent for the probed site, amber for other sites) and a hairline
/// for every click.
struct ProbeWaterfall: View {
    var model: ProbeWaterfallModel
    /// The last step is still collecting hosts.
    var running: Bool

    static let columns: [AnalyzeColumnsLayout.Column] = [.flexible(weight: 1.5, min: 180), .fixed(26), .fixed(34), .flexible(weight: 1, min: 120)]
    static let otherSite = Color(oklch: 0.76, 0.14, 70)

    var body: some View {
        VStack(spacing: 0) {
            AnalyzeHeaderRow(columns: Self.columns, height: 26, horizontalPadding: 0) {
                Text(tr("Host", "SiteProbe"))
                Text(verbatim: "IP").frame(maxWidth: .infinity, alignment: .trailing)
                Text(tr("Reqs", "SiteProbe")).frame(maxWidth: .infinity, alignment: .trailing)
                HStack(spacing: 0) {
                    ForEach(Array(model.tickLabels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(verbatim: label)
                    }
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.ink3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.steps) { step in
                        stepHeader(step, isLive: running && step.index == model.steps.count - 1)
                        ForEach(step.rows) { row in
                            hostRow(row)
                        }
                    }
                }
                .padding(.bottom, 6)
            }

            legend
        }
    }

    private func stepHeader(_ step: ProbeWaterfallModel.Step, isLive: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: String(step.index + 1))
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 17, height: 17)
                .background(isLive ? Theme.accent : Theme.fill2, in: Circle())
                .foregroundStyle(isLive ? Theme.onAccent : Theme.ink)
            Text(ProbeStepText.localized(step.label))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Text(verbatim: String(format: "+%.1fs", step.at))
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
            Text(trn("%lld new host", "%lld new hosts", step.rows.count, "SiteProbe"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
        }
        .padding(.top, 11)
        .padding(.bottom, 5)
    }

    private func hostRow(_ row: ProbeWaterfallModel.Row) -> some View {
        AnalyzeColumnsLayout(columns: Self.columns) {
            Text(row.host)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 8)
                .help(String(format: "+%.1fs", row.firstAt))
            Text(verbatim: String(row.ipCount))
                .font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: String(row.requests))
                .font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ProbeWaterfallBar(row: row, marks: model.marks)
        }
        .font(.system(size: 12))
        .frame(height: 24)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 10, height: 6)
                Text(tr("Same site", "SiteProbe"))
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Self.otherSite).frame(width: 10, height: 6)
                Text(tr("Other sites", "SiteProbe"))
            }
            HStack(spacing: 5) {
                Rectangle().fill(Theme.ink3).frame(width: 1, height: 10)
                Text(tr("Your clicks", "SiteProbe"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.ink2)
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

/// The track of one waterfall row: the activity bar and the click markers.
private struct ProbeWaterfallBar: View {
    var row: ProbeWaterfallModel.Row
    var marks: [Double]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.fill)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Rectangle()
                        .fill(Theme.ink3.opacity(0.5))
                        .frame(width: 1, height: 18)
                        .offset(x: width * mark)
                }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(row.sameSite ? Theme.accent : ProbeWaterfall.otherSite)
                    .frame(width: max(2, width * min(row.width, 1 - row.start)))
                    .offset(x: width * row.start)
                    .animation(.linear(duration: 0.6), value: row.width)
            }
        }
        .frame(height: 10)
    }
}

/// Step labels are stored in English (`Page load`, `Click · /apple/swift`, `Switched to iPhone`);
/// this shows them in the UI language.
@MainActor
enum ProbeStepText {
    static func localized(_ label: String) -> String {
        switch label {
        case "Page load": return tr("Page load", "SiteProbe")
        case "Page load · iPhone": return tr("Page load · iPhone", "SiteProbe")
        case "Switched to iPhone": return tr("Switched to iPhone", "SiteProbe")
        case "Switched to desktop": return tr("Switched to desktop", "SiteProbe")
        default:
            let click = "Click · "
            if label.hasPrefix(click) { return trf("Click · %@", "SiteProbe", String(label.dropFirst(click.count))) }
            return label
        }
    }
}
