import SwiftUI

/// "About this host" section of the request inspector, filled by the on-device model.
/// Placeholder until the insight feature is implemented.
struct HostInsightView: View {
    @Environment(AppModel.self) private var model
    var context: HostContext

    var body: some View {
        EmptyView()
    }
}
