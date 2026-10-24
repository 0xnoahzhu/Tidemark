import SwiftUI

/// Main three-pane window. Placeholder until the shell is implemented.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Tidemark")
            .frame(minWidth: 1000, minHeight: 640)
    }
}
