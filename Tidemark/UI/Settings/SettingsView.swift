import SwiftUI

/// Settings window. Placeholder until settings are implemented.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Settings")
            .frame(width: 560, height: 420)
    }
}
