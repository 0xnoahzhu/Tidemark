import Charts
import SwiftUI

/// Requests over time for the History query: 48 bars, the current one in the accent color.
/// Hovering a bar shows its time window and count; dragging across the chart zooms the History query into
/// the dragged window.
struct RequestsHistogramChart: View {
    var histogram: Histogram
    /// Called with the window dragged across the chart when the drag ends.
    var zoom: (DateInterval) -> Void

    @State private var hovered: Date?
    /// Range selection while the mouse is down. Charts clears it on mouse-up, which commits the zoom.
    @State private var dragged: ClosedRange<Date>?
    @State private var pendingZoom: ClosedRange<Date>?

    var body: some View {
        let bins = RequestsHistogramBin.bins(of: histogram)
        let selected = dragged == nil ? hovered.flatMap { date in bins.first { $0.contains(date) } } : nil
        let ticks = RequestsHistogramBin.axisTicks(of: histogram, now: .now, locale: Localizer.shared.locale, nowLabel: tr("Now", "Requests"))
        // The newest bar is the current one only when the chart reaches now (not in a zoomed past window).
        let endsNow = abs(histogram.end.timeIntervalSinceNow) < 120
        Chart {
            ForEach(bins) { bin in
                bar(bin, highlighted: (bin.isLast && endsNow) || bin.id == selected?.id)
            }
            if let dragged {
                RectangleMark(xStart: .value("From", dragged.lowerBound), xEnd: .value("To", dragged.upperBound))
                    .foregroundStyle(Theme.accent.opacity(0.16))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        RequestsHistogramCallout(text: RequestsHistogramBin.windowLabel(dragged.lowerBound, dragged.upperBound, locale: Localizer.shared.locale))
                    }
            }
            if let selected {
                RuleMark(x: .value("Hovered", selected.middle))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        RequestsHistogramCallout(text: RequestsHistogramBin.windowLabel(selected.start, selected.end, locale: Localizer.shared.locale) + " · " + Fmt.count(selected.count))
                    }
            }
        }
        .chartXScale(domain: histogram.start...max(histogram.end, histogram.start.addingTimeInterval(1)))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: ticks.map(\.date)) { value in
                AxisValueLabel(anchor: anchor(for: value.index, of: ticks)) {
                    if ticks.indices.contains(value.index) {
                        Text(ticks[value.index].label)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXSelection(range: $dragged)
        .onChange(of: dragged) { _, range in
            if let range {
                pendingZoom = range
            } else if let pending = pendingZoom {
                pendingZoom = nil
                if let window = RequestsHistogramBin.zoomWindow(for: pending, in: histogram) { zoom(window) }
            }
        }
        .chartPlotStyle { plot in plot.frame(height: 64) }
        .accessibilityLabel(tr("Requests over time", "Requests"))
        .accessibilityHint(tr("Drag across the chart to zoom into that time.", "Requests"))
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

    /// The first label starts at its tick when it sits at the left edge, the last ends at the right edge,
    /// the others are centered on their tick.
    private func anchor(for index: Int, of ticks: [RequestsHistogramBin.AxisTick]) -> UnitPoint {
        if index == ticks.count - 1 { return .topTrailing }
        let span = histogram.end.timeIntervalSince(histogram.start)
        if index == 0, span > 0, ticks[0].date.timeIntervalSince(histogram.start) / span < 0.08 { return .topLeading }
        return .top
    }
}

/// Hover callout: `14:00–14:30 · 1,204`, or the window being dragged.
private struct RequestsHistogramCallout: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
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

    /// `14:00–14:30`, with seconds for windows under two minutes and the day when it changes:
    /// `Oct 23 22:00–Oct 24 01:30` (the day only appears when the window spans midnight).
    static func windowLabel(_ start: Date, _ end: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let seconds = end.timeIntervalSince(start) < 120
        func time(_ date: Date) -> String { seconds ? Fmt.hms(date) : Fmt.hm(date) }
        if calendar.isDate(start, inSameDayAs: end) { return time(start) + "–" + time(end) }
        return Fmt.monthDay(start, locale: locale) + " " + time(start) + "–" + Fmt.monthDay(end, locale: locale) + " " + time(end)
    }

    // MARK: Zoom

    /// Shortest window the chart zooms into.
    static let minimumZoom: TimeInterval = 60

    /// The dragged range clamped to the chart, or nil when it is too short to be a deliberate drag (less
    /// than a minute or half a bar).
    static func zoomWindow(for range: ClosedRange<Date>, in histogram: Histogram) -> DateInterval? {
        let start = max(range.lowerBound, histogram.start)
        let end = min(range.upperBound, histogram.end)
        let bucket = histogram.end.timeIntervalSince(histogram.start) / Double(max(histogram.counts.count, 1))
        guard end.timeIntervalSince(start) >= max(minimumZoom, bucket / 2) else { return nil }
        return DateInterval(start: start, end: end)
    }

    // MARK: Axis

    /// A labelled position on the time axis.
    struct AxisTick: Equatable {
        var date: Date
        var label: String
    }

    /// Tick spacings tried in order; the first that splits the range into at most five parts wins.
    static let tickSteps: [TimeInterval] = [
        10, 15, 30, 60, 120, 300, 600, 900, 1800,
        3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600,
        86400, 2 * 86400, 7 * 86400, 14 * 86400, 30 * 86400, 91 * 86400, 182 * 86400, 365 * 86400,
    ]

    /// The design's axis: ticks on round times (24 hours → `Oct 23 14:00 · 20:00 · Oct 24 02:00 · 08:00 ·
    /// Now`), the date only where the day changes, and the range's end labelled "Now" when it is now.
    static func axisTicks(of histogram: Histogram, now: Date, locale: Locale, calendar: Calendar = .current, nowLabel: String) -> [AxisTick] {
        let start = histogram.start, end = histogram.end
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let step = tickSteps.first { $0 >= span / 5 } ?? tickSteps[tickSteps.count - 1]
        let byDay = step >= 86400

        var dates: [Date] = []
        var tick = firstTick(atOrAfter: start, step: step, calendar: calendar)
        // Ticks stop half a step before the end so they never crowd its label.
        while end.timeIntervalSince(tick) >= step / 2 {
            dates.append(tick)
            guard let next = byDay ? calendar.date(byAdding: .day, value: Int(step / 86400), to: tick) : tick.addingTimeInterval(step) else { break }
            tick = next
        }

        func timeOfDay(_ date: Date) -> String { step < 60 ? Fmt.hms(date) : Fmt.hm(date) }
        var ticks: [AxisTick] = []
        var previous: Date?
        for date in dates {
            let label: String
            if byDay {
                label = Fmt.monthDay(date, locale: locale)
            } else {
                let newDay = previous.map { !calendar.isDate($0, inSameDayAs: date) } ?? (span > 6 * 3600)
                label = newDay ? Fmt.monthDay(date, locale: locale) + " " + timeOfDay(date) : timeOfDay(date)
            }
            ticks.append(AxisTick(date: date, label: label))
            previous = date
        }

        let endLabel: String
        if abs(now.timeIntervalSince(end)) < 120 {
            endLabel = nowLabel
        } else if byDay || previous.map({ !calendar.isDate($0, inSameDayAs: end) }) ?? (span > 6 * 3600) {
            endLabel = Fmt.monthDay(end, locale: locale) + " " + timeOfDay(end)
        } else {
            endLabel = timeOfDay(end)
        }
        ticks.append(AxisTick(date: end, label: endLabel))
        return ticks
    }

    /// The first round time at or after `start`: the next multiple of `step` within the hour for steps under
    /// an hour, the next full hour for steps under a day, the next midnight beyond.
    private static func firstTick(atOrAfter start: Date, step: TimeInterval, calendar: Calendar) -> Date {
        if step >= 86400 {
            let day = calendar.startOfDay(for: start)
            return day == start ? day : calendar.date(byAdding: .day, value: 1, to: day) ?? start
        }
        guard let hour = calendar.dateInterval(of: .hour, for: start)?.start else { return start }
        let unit = min(step, 3600)
        let offset = start.timeIntervalSince(hour)
        return hour.addingTimeInterval((offset / unit).rounded(.up) * unit)
    }
}
