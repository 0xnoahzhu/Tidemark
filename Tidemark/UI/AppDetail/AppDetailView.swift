import SwiftUI

/// Page of one monitored app: header, stats and the Requests / Domains & IPs / Process Tree tabs. Placeholder until it is implemented.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    var appID: AppID

    var body: some View {
        Text("App")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
