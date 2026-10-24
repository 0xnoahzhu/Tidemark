import SwiftUI

/// Notifications page: first contact with a new domain or IP by a monitored app. Placeholder until it is implemented.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Notifications")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
