import SwiftUI

/// Snippet shown by `TodaySummaryIntent` in Shortcuts and Spotlight: two large figures with labels.
/// Uses system colors only, because the snippet is rendered outside Tidemark.
struct IntentsSummarySnippet: View {
    var requests: String
    var requestsLabel: String
    var destinations: String
    var destinationsLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            figure(requests, requestsLabel, tint: .accentColor)
            figure(destinations, destinationsLabel, tint: .orange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func figure(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
