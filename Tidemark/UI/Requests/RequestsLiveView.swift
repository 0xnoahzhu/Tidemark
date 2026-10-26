import SwiftUI

/// Live mode of the Requests page: the newest rows of the Surge stream (plus rows other Macs wrote).
///
/// The engine updates the stream every 250 ms; the table takes it in at most twice a second, or once a second when
/// the system asks apps to reduce resource usage (macOS 27, Low Power Mode, thermal pressure), since every update
/// re-renders the table. The filter and the Mac scope apply at once.
struct RequestsLiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResources

    /// The stream as the table shows it: `model.live.rows` at the last refresh. Nil until the first refresh, while
    /// the table reads the stream itself, so the page never opens on an empty table.
    @State private var snapshot: [RequestRecord]?
    /// Bumped once fresh rows have aged out, so their highlight fades even when nothing new arrives.
    @State private var freshTick = 0

    var body: some View {
        @Bindable var nav = model.nav
        let stream = snapshot ?? model.live.rows
        let rows = RequestsPresentation.liveRows(
            stream,
            scope: model.devices.scope,
            search: nav.requestSearch,
            identity: model.requestsIdentity(for:)
        )
        let _ = freshTick
        let now = Date.now
        VStack(spacing: 0) {
            RequestsTable(model: model, rows: rows, selection: $nav.selectedRequest, timeStyle: .clock, now: now)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .overlay {
                    if rows.isEmpty { RequestsLiveEmptyState(streamIsEmpty: stream.isEmpty) }
                }
            RequestsLiveFooter(shown: rows.count)
        }
        .task(id: reducedResources) {
            let interval: Duration = reducedResources ? .seconds(1) : .milliseconds(500)
            let live = model.live
            // Each value is the stream as it is when the loop asks for it, so updates during the pause are
            // taken in together.
            for await rows in Observations({ live.rows }) {
                snapshot = rows
                try? await Task.sleep(for: interval)
            }
        }
        .task(id: rows.first?.key) {
            guard let newest = rows.first, RequestsPresentation.isFresh(newest, now: .now) else { return }
            let remaining = RequestsPresentation.freshInterval - Date.now.timeIntervalSince(newest.startedAt)
            try? await Task.sleep(for: .seconds(max(0.05, remaining + 0.05)))
            if !Task.isCancelled { freshTick &+= 1 }
        }
    }
}

/// `24 most recent shown · 44 written this session` … `surge-cli --raw watch request`
private struct RequestsLiveFooter: View {
    @Environment(AppModel.self) private var model
    var shown: Int

    var body: some View {
        HStack(spacing: 8.px) {
            Text(trf("%1$@ most recent shown · %2$@ written this session", "Requests", Fmt.count(shown), Fmt.count(model.live.writtenThisSession)))
                .contentTransition(.numericText())
            Spacer(minLength: 8.px)
            Text(verbatim: "surge-cli --raw watch request")
                .font(Theme.mono(11))
        }
        .font(.design(11))
        .foregroundStyle(Theme.ink3)
        .lineLimit(1)
        .padding(.horizontal, 14.px)
        .frame(height: 28.px)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Shown over the empty live table: why nothing is arriving.
private struct RequestsLiveEmptyState: View {
    @Environment(AppModel.self) private var model
    /// The stream the table shows has no rows at all (rather than only none that match).
    var streamIsEmpty: Bool

    var body: some View {
        let search = model.nav.requestSearch.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            EmptyState(systemImage: "magnifyingglass", title: trf("No requests match “%@”", "Requests", search), message: tr("The filter looks at host, remote IP, process and app.", "Requests"))
        } else if !streamIsEmpty {
            EmptyState(systemImage: "line.3.horizontal.decrease.circle", title: tr("No requests match these filters", "Requests"), message: tr("Check the Mac menu in the sidebar.", "Requests"))
        } else if case .failed(let error) = model.live.surge {
            EmptyState(systemImage: "bolt.horizontal.circle", title: tr("Surge isn't connected", "Requests"), message: CaptureEngine.message(for: error))
        } else if !model.live.recording {
            EmptyState(systemImage: "pause.circle", title: tr("Recording is paused", "Requests"), message: tr("Resume recording to see requests as Surge handles them.", "Requests"))
        } else {
            EmptyState(systemImage: "dot.radiowaves.left.and.right", title: tr("Waiting for requests", "Requests"), message: tr("Requests appear here as soon as Surge handles them.", "Requests"))
        }
    }
}
