import SwiftUI

/// Egress IP page: current egress, per-policy egress, change log, IP lookup and this Mac's network. Placeholder until it is implemented.
struct EgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Egress IP")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
