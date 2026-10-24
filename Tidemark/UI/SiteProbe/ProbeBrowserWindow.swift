import SwiftUI

/// Pop-out browser window of a running site probe. Placeholder until Site Probe is implemented.
struct ProbeBrowserWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Site Probe")
            .frame(minWidth: 640, minHeight: 480)
    }
}
