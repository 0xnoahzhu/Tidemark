import SwiftUI

/// Requests page: the live table and the stored history, each opening the selected request in the inspector.
struct RequestsView: View {
    @Environment(AppModel.self) private var model
    /// History has been shown since the page opened (see `RequestsHistoryView.init`).
    @State private var historyShown = false

    var body: some View {
        @Bindable var nav = model.nav
        Group {
            if nav.requestsLive {
                RequestsLiveView()
            } else {
                // History's filters wrap onto a second line in a narrow column; a minimum height that followed
                // them would change while the inspector opens or the window narrows, as the inspector's would.
                RequestsHistoryView(history: model.requestsHistory, opensPage: !historyShown)
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .onAppear { historyShown = true }
            }
        }
        // The content runs beneath the sidebar and the inspector, so its minimum width holds both of theirs, and the
        // split view adds the sidebar's again. Any width of the content's own takes that sum past a window near its
        // minimum once the inspector opens, and AppKit then aborts after resizing the columns back and forth. The
        // content asks for none; the table scrolls horizontally instead.
        .frame(minWidth: 0, maxWidth: .infinity)
        // Inside the inspector's split view rather than above it, where the split view would blur the top of both
        // columns under its own band.
        .pageTopLine()
        .inspector(isPresented: Binding(
            get: { nav.selectedRequest != nil },
            set: { if !$0 { nav.selectedRequest = nil } }
        )) {
            // The inspector's minimum size must not follow its content: its host title and URL wrap, so a
            // width-dependent minimum height changes on every pass while the column opens, and AppKit aborts
            // after more update-constraints passes than the window has views. `inspectorColumnWidth` sets the width.
            RequestsInspectorFill {
                RequestsInspectorHost()
            }
            .pageTopLine()
            .inspectorColumnWidth(min: 280.px, ideal: 316.px, max: 440.px)
        }
        .pageToolbar(tr("Requests", "Requests"), subtitle: tr("Every request Surge sees, kept in PostgreSQL", "Requests"), topLine: false) {
            RequestsToolbar(model: model)
        }
        .onChange(of: nav.requestsLive) {
            // Live is no place to show a stored request; one History is to show replaces the selection itself.
            if nav.requestsLive { nav.revealing = nil }
            if nav.revealing == nil { nav.selectedRequest = nil }
        }
    }
}

/// Live / History switch, the filter field and the recording button, in the design's order (`searchable`
/// would put the filter field last).
///
/// Toolbar items can be re-hosted in the overflow menu, so they get the model passed in rather than
/// relying on the environment.
private struct RequestsToolbar: ToolbarContent {
    var model: AppModel

    var body: some ToolbarContent {
        @Bindable var nav = model.nav
        ToolbarItem(placement: .primaryAction) {
            DesignSegmentedControl(tr("Mode", "Requests"), selection: $nav.requestsLive, size: .compact(), segments: [
                .init(true, tr("Live", "Requests"), systemImage: "dot.radiowaves.left.and.right"),
                .init(false, tr("History", "Requests"), systemImage: "clock.arrow.circlepath"),
            ])
            .help(tr("Switch between the live stream and stored history", "Requests"))
        }
        // The control draws its own track, as on the page, rather than sitting in a glass bubble.
        .sharedBackgroundVisibility(.hidden)
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            ToolbarSearchField(text: $nav.requestSearch, prompt: tr("Filter host, IP, process", "Requests"))
                .frame(width: 200.px)
        }
        // Outlasts Live / History in a narrow window: the field has no usable form in the overflow menu.
        .visibilityPriority(Self.searchPriority)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            RequestsRecordingButton(model: model)
        }
        .visibilityPriority(ToolbarItemVisibilityPriority(higherThan: Self.searchPriority))
    }

    private static let searchPriority = ToolbarItemVisibilityPriority(higherThan: .high)
}

/// `● Recording` with a pulsing red dot, or `■ Resume` while paused; asks before switching.
private struct RequestsRecordingButton: View {
    var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResources

    var body: some View {
        let recording = model.live.recording
        Button {
            model.nav.confirmRecordingToggle = true
        } label: {
            HStack(spacing: 7.px) {
                if recording {
                    StatusDot(color: Theme.recording, size: 8.px, pulsing: !reduceMotion && !reducedResources)
                } else {
                    RoundedRectangle(cornerRadius: 2.px, style: .continuous)
                        .fill(Theme.ink3)
                        .frame(width: 8.px, height: 8.px)
                }
                Text(recording ? tr("Recording", "Requests") : tr("Resume", "Requests"))
                    .font(.design(12, .medium))
            }
            .padding(.horizontal, 4.px)
        }
        .help(recording ? tr("Recording to PostgreSQL. Click to pause.", "Requests") : tr("Recording is paused. Click to resume.", "Requests"))
        .accessibilityLabel(recording ? tr("Pause Recording…", "Requests") : tr("Resume Recording…", "Requests"))
    }
}

/// Resolves the selected request among the rows Live or History shows, and keeps showing the last version once it
/// has scrolled out of the live buffer or left History's results.
private struct RequestsInspectorHost: View {
    @Environment(AppModel.self) private var model
    @State private var cached: RequestRecord?

    var body: some View {
        let key = model.nav.selectedRequest
        let rows = model.nav.requestsLive ? model.live.rows : model.requestsHistory.rows
        let current = key.flatMap { key in rows.first { $0.key == key } }
        let record = current ?? (cached?.key == key ? cached : nil)
        Group {
            if let record {
                RequestsInspector(record: record) { model.nav.selectedRequest = nil }
            } else {
                EmptyState(systemImage: "sidebar.right", title: tr("No request selected", "Requests"), message: nil)
            }
        }
        .onChange(of: current) { _, newValue in
            if let newValue { cached = newValue }
        }
    }
}
