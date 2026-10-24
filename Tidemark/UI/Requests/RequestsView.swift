import SwiftUI

/// Requests page: the live table with its inspector, and the stored history.
struct RequestsView: View {
    @Environment(AppModel.self) private var model
    @State private var history = RequestsHistoryModel()

    var body: some View {
        @Bindable var nav = model.nav
        Group {
            if nav.requestsLive {
                RequestsLiveView()
            } else {
                RequestsHistoryView(history: history)
            }
        }
        .inspector(isPresented: Binding(
            get: { nav.selectedRequest != nil },
            set: { if !$0 { nav.selectedRequest = nil } }
        )) {
            RequestsInspectorHost(history: history)
                .inspectorColumnWidth(min: 280, ideal: 316, max: 440)
        }
        .navigationTitle(tr("Requests", "Requests"))
        .navigationSubtitle(tr("Every request Surge sees, kept in PostgreSQL", "Requests"))
        .searchable(text: $nav.requestSearch, placement: .toolbar, prompt: Text(tr("Filter host, IP, process", "Requests")))
        .toolbar { RequestsToolbar(model: model) }
        .onChange(of: nav.requestsLive) { nav.selectedRequest = nil }
    }
}

/// Live / History switch, filter options and the recording button. The filter field itself is the
/// window's toolbar search field (`searchable`), which macOS places at the trailing edge.
///
/// Toolbar items can be re-hosted in the overflow menu, so they get the model passed in rather than
/// relying on the environment.
private struct RequestsToolbar: ToolbarContent {
    var model: AppModel

    var body: some ToolbarContent {
        @Bindable var nav = model.nav
        ToolbarItem(placement: .primaryAction) {
            Picker(tr("Mode", "Requests"), selection: $nav.requestsLive) {
                Text(tr("Live", "Requests")).tag(true)
                Text(tr("History", "Requests")).tag(false)
            }
            .pickerStyle(.tabs)
            .labelsHidden()
            .help(tr("Switch between the live stream and stored history", "Requests"))
        }
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            RequestsFilterOptionsMenu(model: model)
        }
        .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .automatic))

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            RequestsRecordingButton(model: model)
        }
        .visibilityPriority(ToolbarItemVisibilityPriority(higherThan: .high))
    }
}

/// "Monitored Only" and "Hide Apple Services" (Settings › Requests preferences).
private struct RequestsFilterOptionsMenu: View {
    var model: AppModel

    var body: some View {
        @Bindable var preferences = model.preferences
        let active = preferences.monitoredOnly || preferences.hideAppleServices
        Menu {
            Toggle(tr("Monitored Only", "Requests"), isOn: $preferences.monitoredOnly)
            Toggle(tr("Hide Apple Services", "Requests"), isOn: $preferences.hideAppleServices)
        } label: {
            Label(tr("Filter Options", "Requests"), systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help(tr("Filter Options", "Requests"))
    }
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
            HStack(spacing: 7) {
                if recording {
                    StatusDot(color: Theme.recording, size: 8, pulsing: !reduceMotion && !reducedResources)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.ink3)
                        .frame(width: 8, height: 8)
                }
                Text(recording ? tr("Recording", "Requests") : tr("Resume", "Requests"))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 4)
        }
        .help(recording ? tr("Recording to PostgreSQL. Click to pause.", "Requests") : tr("Recording is paused. Click to resume.", "Requests"))
        .accessibilityLabel(recording ? tr("Pause Recording…", "Requests") : tr("Resume Recording…", "Requests"))
    }
}

/// Resolves the selected request (live rows first, then history rows) and keeps showing the last
/// version once it has scrolled out of the live buffer.
private struct RequestsInspectorHost: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel
    @State private var cached: RequestRecord?

    var body: some View {
        let key = model.nav.selectedRequest
        let current = key.flatMap { key in
            model.live.rows.first { $0.key == key } ?? history.rows.first { $0.key == key }
        }
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
