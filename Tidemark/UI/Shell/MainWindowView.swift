import SwiftUI

/// Main three-pane window: Liquid Glass sidebar, one page per destination, and the window-wide sheets
/// and confirmations (Monitor an App, pause / resume recording, stop / restart monitoring an app).
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var nav = model.nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebar()
                .navigationSplitViewColumnWidth(min: 220.px, ideal: 244.px, max: 320.px)
        } detail: {
            // Pages wrap text to their width; a minimum height that followed it would change while a column
            // resizes and send the split view into update-constraints passes until AppKit aborts.
            ShellDetail(page: nav.page)
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: UIScale.minimumWindowSize.width, minHeight: UIScale.minimumWindowSize.height)
        .sheet(isPresented: $nav.showAddApp) {
            AddAppSheet()
        }
        .modifier(ShellRecordingConfirmation())
        .modifier(AppMonitoringConfirmation())
        #if DEBUG
        .task { ShellDemoData.installIfRequested(into: model) }
        #endif
    }
}

/// The detail column for the selected sidebar destination.
private struct ShellDetail: View {
    @Environment(AppModel.self) private var model
    var page: Page

    var body: some View {
        switch page {
        case .requests:
            RequestsView()
        case .notifications:
            NotificationsView()
        case .inventory:
            InventoryView()
        case .probe:
            SiteProbeView()
        case .egress:
            EgressView()
        case .app(let id):
            AppDetailView(appID: id, cache: model.appPages)
        }
    }
}

/// "Pause recording?" / "Resume recording?" confirmation, presented when `Navigation.confirmRecordingToggle`
/// is set (Requests toolbar, Capture menu, menu bar panel). As in the page, it is a glass dialog over the window
/// with the app icon, Cancel and a red Pause or an accent Resume.
struct ShellRecordingConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let nav = model.nav
        let pausing = model.live.recording
        content.glassDialog(isPresented: nav.confirmRecordingToggle, onCancel: { nav.confirmRecordingToggle = false }) {
            GlassDialog(
                width: 290,
                surface: .dialog,
                title: pausing ? tr("Pause recording?", "Shell") : tr("Resume recording?", "Shell"),
                message: pausing
                    ? tr("Requests Surge handles from now on won't be saved to PostgreSQL, and no new-site alerts will fire until you resume. Recording turns back on by itself the next time Tidemark starts.", "Shell")
                    : tr("Every request Surge sees will be saved to PostgreSQL again, and alerts turn back on. Nothing from the paused period is filled in.", "Shell"),
                cancelTitle: tr("Cancel", "Shell"),
                confirmTitle: pausing ? tr("Pause", "Shell") : tr("Resume", "Shell"),
                tone: pausing ? .destructive : .accent,
                onCancel: { nav.confirmRecordingToggle = false },
                onConfirm: {
                    nav.confirmRecordingToggle = false
                    model.capture.setRecording(!pausing)
                }
            ) {
                // The asset keeps the system icon margin; drawn a quarter larger, its tile fills the page's 58 px.
                let tile = 58.px, drawn = tile * 1.25
                Image("BrandIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drawn, height: drawn)
                    .padding(-(drawn - tile) / 2)
            }
        }
    }
}
