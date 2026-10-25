import AppKit
import SwiftUI

/// Main three-pane window: Liquid Glass sidebar, one page per destination, and the window-wide sheets
/// and confirmations (Monitor an App, pause / resume recording).
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var nav = model.nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 320)
        } detail: {
            // Pages wrap text to their width; a minimum height that followed it would change while a column
            // resizes and send the split view into update-constraints passes until AppKit aborts.
            ShellDetail(page: nav.page)
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 640)
        .sheet(isPresented: $nav.showAddApp) {
            AddAppSheet()
        }
        .modifier(ShellRecordingConfirmation())
        #if DEBUG
        .task { ShellDemoData.installIfRequested(into: model) }
        #endif
    }
}

/// The detail column for the selected sidebar destination.
private struct ShellDetail: View {
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
            AppDetailView(appID: id)
                .id(id)
        }
    }
}

/// "Pause recording?" / "Resume recording?" confirmation, presented when `Navigation.confirmRecordingToggle`
/// is set (Requests toolbar, Capture menu, menu bar panel). As in the design, the dialog carries the app icon
/// and its confirming button is the default one (Pause draws as the filled red default button).
struct ShellRecordingConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var nav = model.nav
        let pausing = model.live.recording
        content.alert(
            pausing ? tr("Pause recording?", "Shell") : tr("Resume recording?", "Shell"),
            isPresented: $nav.confirmRecordingToggle
        ) {
            Button(tr("Cancel", "Shell"), role: .cancel) {}
            if pausing {
                Button(tr("Pause", "Shell"), role: .destructive) {
                    model.capture.setRecording(false)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button(tr("Resume", "Shell")) {
                    model.capture.setRecording(true)
                }
                .keyboardShortcut(.defaultAction)
            }
        } message: {
            Text(pausing
                ? tr("Requests Surge handles from now on won't be saved to PostgreSQL, and no new-site alerts will fire until you resume. Recording turns back on by itself the next time Tidemark starts.", "Shell")
                : tr("Every request Surge sees will be saved to PostgreSQL again, and alerts turn back on. Nothing from the paused period is filled in.", "Shell"))
        }
        .dialogIcon(Image(nsImage: NSApp.applicationIconImage))
    }
}
