import SwiftUI

/// "About this host" section of the request inspector, filled by the on-device model.
///
/// Shows a cached insight (this Mac's or one another Mac stored in the database) as soon as the
/// inspector opens; otherwise offers "Explain with Apple Intelligence" while the model is available.
struct HostInsightView: View {
    @Environment(AppModel.self) private var model
    var context: HostContext

    @State private var phase: Phase = .checking
    /// Host the user asked to explain; a different selected host resets the request.
    @State private var explainHost: String?
    /// Bumped by "Try Again" to rerun the request.
    @State private var attempt = 0

    private enum Phase: Equatable {
        /// Looking for a cached insight.
        case checking
        /// Nothing cached; the model has not been asked.
        case idle
        case loading
        case loaded(HostInsight)
        case failed(String)
    }

    private struct LoadKey: Equatable {
        var host: String
        var language: String
        var explain: Bool
        var attempt: Int
    }

    var body: some View {
        let key = LoadKey(host: context.host, language: Localizer.shared.languageCode, explain: explainHost == context.host, attempt: attempt)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: tr("About this host", "Insight"))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: phase)
        .task(id: key) { await load(key) }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loaded(let insight):
            HostInsightCard(insight: insight)
                .transition(.opacity)
        case .loading:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(tr("Thinking…", "Insight"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(minHeight: 22)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.insights.isAvailable {
                    Button(tr("Try Again", "Insight")) { attempt += 1 }
                        .controlSize(.small)
                }
            }
        case .idle, .checking:
            if model.insights.isAvailable {
                Button {
                    explainHost = context.host
                } label: {
                    Label(tr("Explain with Apple Intelligence", "Insight"), systemImage: "apple.intelligence")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .opacity(phase == .checking ? 0 : 1)
                .disabled(phase == .checking)
            } else {
                Text(model.insights.unavailableReason ?? tr("The on-device model is unavailable.", "Insight"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(phase == .checking ? 0 : 1)
            }
        }
    }

    private func load(_ key: LoadKey) async {
        if case .loaded(let current) = phase, current.host == HostInsightService.normalizedHost(key.host),
           current.language == key.language || key.explain {
            return
        }
        let insights = model.insights
        guard key.explain else {
            phase = .checking
            let cached = await cachedInsight(for: key.host, language: key.language)
            guard !Task.isCancelled else { return }
            if let cached {
                phase = .loaded(cached)
            } else {
                phase = .idle
                insights.prewarm()
            }
            return
        }
        phase = .loading
        do {
            let insight = try await insights.insight(for: context)
            guard !Task.isCancelled else { return }
            phase = .loaded(insight)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func cachedInsight(for host: String, language: String) async -> HostInsight? {
        if let cached = await model.insights.cachedInsight(for: host) { return cached }
        return try? await model.database.hostInsight(HostInsightService.normalizedHost(host), language: language)
    }
}

/// The model's answer: category chip, operator, summary, optional concern and a provenance footnote.
struct HostInsightCard: View {
    var insight: HostInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HostInsightCategoryChip(category: insight.category)
                if let operatorName = insight.operatorName {
                    Text(operatorName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Text(insight.summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let concern = insight.concern {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.warning)
                    Text(concern)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.amberInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Label {
                Text(trf("On-device · %@", "Insight", insight.model ?? "Apple Intelligence"))
            } icon: {
                Image(systemName: "apple.intelligence")
            }
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.ink3)
        }
    }
}

/// Category capsule tinted by `HostInsightStyle.hue`.
struct HostInsightCategoryChip: View {
    var category: HostCategory

    var body: some View {
        let colors = HostInsightStyle.hue(for: category).map(Theme.tint) ?? (Theme.fill2, Theme.ink2)
        Text(HostInsightStyle.label(for: category))
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(colors.0, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(colors.1)
            .fixedSize()
    }
}
