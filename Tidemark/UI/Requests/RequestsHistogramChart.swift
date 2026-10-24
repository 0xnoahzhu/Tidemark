import Charts
import SwiftUI

/// Requests over time for the History query: 48 bars, the newest in the accent color.
/// Hovering a bar shows its time window and count.
struct RequestsHistogramChart: View {
    var histogram: Histogram

    @State private var hovered: Date?

    var body: some View {
        let bins = RequestsHistogramBin.bins(of: histogram)
        let selected = hovered.flatMap { date in bins.first { $0.contains(date) } }
        Chart {
            ForEach(bins) { bin in
                bar(bin, highlighted: bin.isLast || bin.id == selected?.id)
            }
            if let selected {
                RuleMark(x: .value("Hovered", selected.middle))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        RequestsHistogramCallout(bin: selected)
                    }
            }
        }
        .chartXScale(domain: histogram.start...max(histogram.end, histogram.start.addingTimeInterval(1)))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: RequestsHistogramBin.axisDates(of: histogram)) { value in
                AxisValueLabel(anchor: anchor(for: value.index, count: value.count)) {
                    if let date = value.as(Date.self) {
                        Text(label(for: date, index: value.index, count: value.count))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
        .chartXSelection(value: $hovered)
        .chartPlotStyle { plot in plot.frame(height: 64) }
        .accessibilityLabel(tr("Requests over time", "Requests"))
    }

    /// A bar spanning its time bucket; `RectangleMark` because `BarMark` has no ranged-x, ranged-y form.
    private func bar(_ bin: RequestsHistogramBin, highlighted: Bool) -> some ChartContent {
        let zero: Int64 = 0
        return RectangleMark(
            xStart: .value("Start", bin.start),
            xEnd: .value("End", bin.barEnd),
            yStart: .value("Zero", zero),
            yEnd: .value("Requests", bin.count)
        )
        .foregroundStyle(highlighted ? Theme.accent : Theme.accentTint)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
    }

    private func label(for date: Date, index: Int, count: Int) -> String {
        if index == count - 1, abs(date.timeIntervalSinceNow) < 120 { return tr("Now", "Requests") }
        return RequestsHistogramBin.axisLabel(date, span: histogram.end.timeIntervalSince(histogram.start), locale: Localizer.shared.locale)
    }

    private func anchor(for index: Int, count: Int) -> UnitPoint {
        if index == 0 { return .topLeading }
        if index == count - 1 { return .topTrailing }
        return .top
    }
}

/// Hover callout: `14:00–14:30 · 1,204`.
private struct RequestsHistogramCallout: View {
    var bin: RequestsHistogramBin

    var body: some View {
        Text(verbatim: "\(Fmt.hm(bin.start))–\(Fmt.hm(bin.end)) · \(Fmt.count(bin.count))")
            .font(Theme.mono(10.5, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.card, in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

/// One bucket of a `Histogram`.
struct RequestsHistogramBin: Identifiable, Equatable {
    var id: Int
    var start: Date
    var end: Date
    var count: Int64
    var isLast: Bool

    /// Bars stop short of the next bucket, leaving the prototype's 3 pt gaps.
    var barEnd: Date { start.addingTimeInterval(end.timeIntervalSince(start) * 0.82) }
    var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    static func bins(of histogram: Histogram) -> [RequestsHistogramBin] {
        let n = histogram.counts.count
        guard n > 0 else { return [] }
        let width = max(histogram.end.timeIntervalSince(histogram.start), 1) / Double(n)
        return histogram.counts.enumerated().map { i, count in
            let start = histogram.start.addingTimeInterval(Double(i) * width)
            return RequestsHistogramBin(id: i, start: start, end: start.addingTimeInterval(width), count: count, isLast: i == n - 1)
        }
    }

    /// Start, middle and end of the range (the prototype labels start / middle / "Now").
    static func axisDates(of histogram: Histogram) -> [Date] {
        let span = histogram.end.timeIntervalSince(histogram.start)
        return [histogram.start, histogram.start.addingTimeInterval(span / 2), histogram.end]
    }

    /// `14:00` for short ranges, `Oct 23 14:00` within a month, `Oct 23` beyond.
    static func axisLabel(_ date: Date, span: TimeInterval, locale: Locale) -> String {
        if span <= 6 * 3600 { return Fmt.hm(date) }
        if span <= 8 * 86400 {
            return Fmt.monthDay(date, locale: locale) + " " + Fmt.hm(date)
        }
        return Fmt.monthDay(date, locale: locale)
    }
}
