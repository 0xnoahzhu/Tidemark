import SwiftUI

/// Menu bar popover. Placeholder until the menu bar extra is implemented.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Tidemark")
            .padding()
            .frame(width: 320)
    }
}

/// Menu bar status item label (template glyph). Placeholder.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: "chart.dots.scatter")
    }
}
