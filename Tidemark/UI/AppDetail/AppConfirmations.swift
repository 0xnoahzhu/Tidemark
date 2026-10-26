import SwiftUI

/// "Stop monitoring Raycast?" / "Monitor Raycast again?", presented over the main window whenever
/// `Navigation.confirmMonitoringToggle` names an app (the app page's Monitoring switch). As in the page, it is a
/// glass dialog with the app's tile, Cancel and a red Stop Monitoring or an accent Start Monitoring.
struct AppMonitoringConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let nav = model.nav
        let app = nav.confirmMonitoringToggle.flatMap { model.catalog.app($0) }
        content.glassDialog(isPresented: app != nil, onCancel: { nav.confirmMonitoringToggle = nil }) {
            if let app {
                let monitoring = model.catalog.isMonitoring(app.id)
                GlassDialog(
                    width: 300,
                    surface: .appDialog,
                    title: monitoring
                        ? trf("Stop monitoring %@?", "AppDetail", app.name)
                        : trf("Monitor %@ again?", "AppDetail", app.name),
                    message: monitoring
                        ? trf("Its requests are still recorded in the global log, but they won't be added to %@'s domain and IP lists or trigger alerts. Monitoring turns back on the next time Tidemark starts.", "AppDetail", app.name)
                        : trf("New domains and IPs from %@ and everything it launches will be added to its lists and alert again.", "AppDetail", app.name),
                    cancelTitle: tr("Cancel", "AppDetail"),
                    confirmTitle: monitoring ? tr("Stop Monitoring", "AppDetail") : tr("Start Monitoring", "AppDetail"),
                    tone: monitoring ? .destructive : .accent,
                    onCancel: { nav.confirmMonitoringToggle = nil },
                    onConfirm: {
                        nav.confirmMonitoringToggle = nil
                        model.capture.setMonitoring(app.id, enabled: !monitoring)
                    }
                ) {
                    AppTile(app: app, size: 52.px)
                }
            }
        }
    }
}

/// "Delete Raycast?": the page's delete sheet. The app's tile sits beside the title, the message says what
/// deleting removes and what stays (at the design's line height of 1.6), and the design's 28 px Cancel and red Delete
/// close it at the right.
struct AppDeleteConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    var app: MonitoredApp
    /// The app's stored requests, which stay in the global log.
    var requests: Int64
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12.px) {
            HStack(spacing: 12.px) {
                AppTile(app: app, size: 40.px)
                Text(trf("Delete %@?", "AppDetail", app.name))
                    .font(.design(15, .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(trf("This removes %1$@'s domain and IP lists, its alerts and its settings. Its %2$@ requests stay in the global request log, because every request is recorded anyway.",
                     "AppDetail", app.name, Fmt.count(requests)))
                .font(.design(12.5))
                .lineHeight(.multiple(factor: 1.6))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.px) {
                Spacer(minLength: 0)
                Button(tr("Cancel", "AppDetail")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(DesignButtonStyle(horizontalPadding: 12))
                Button(tr("Delete", "AppDetail"), role: .destructive) {
                    dismiss()
                    onDelete()
                }
                .buttonStyle(DesignButtonStyle(kind: .destructive, horizontalPadding: 12))
            }
            .padding(.top, 4.px)
        }
        .padding(20.px)
        .frame(width: 420.px)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
    }
}
