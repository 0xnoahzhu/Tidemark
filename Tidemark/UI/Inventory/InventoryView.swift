import SwiftUI

/// Global Domains & IPs page, deduplicated across every app and probe. Placeholder until it is implemented.
struct InventoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Domains & IPs")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
