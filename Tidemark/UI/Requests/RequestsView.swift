import SwiftUI

/// Requests page: live table with inspector, and history. Placeholder until it is implemented.
struct RequestsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Requests")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
