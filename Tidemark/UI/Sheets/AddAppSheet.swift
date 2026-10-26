import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Monitor an App": pick a running app (or any `.app` bundle) and start collecting everything it and its
/// child processes send, backfilled from the requests already in the database.
struct AddAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [AppCandidate] = []
    @State private var loaded = false
    @State private var selection: String?
    @State private var working = false
    @State private var failure: (any Error)?

    /// A candidate's row, as in the design: its name and path (two lines, taller than the 28 px tile) with 8 px above
    /// and below.
    static let rowHeight = 47.px
    /// Between two rows.
    private static let rowSpacing = 2.px
    /// The rows the list shows before it scrolls.
    static let visibleRows = visibleRows(minimumWindowHeight: UIScale.minimumWindowSize.height, factor: UIScale.factor)

    /// What the sheet takes besides its rows, in design px: the title and a two-line subtitle, RUNNING NOW, the
    /// Choose Another App… line with two lines of help, the footer and the paddings between them (213 in English),
    /// with room for a line more.
    static let chromeHeight: CGFloat = 230

    /// Six rows, or five where six would make the sheet taller than the main window at its minimum height, under
    /// whose toolbar it hangs. At the design's minimum window six always fit; five are for a screen too small for
    /// it, which cuts the window's minimum.
    static func visibleRows(minimumWindowHeight: CGFloat, factor: CGFloat) -> Int {
        // Six rows of 47 px, 2 px apart.
        let sixRows = UIScale.length(chromeHeight + 6 * (47 + 2), factor: factor)
        return sixRows <= minimumWindowHeight ? 6 : 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3.px) {
                Text(tr("Monitor an App", "Sheets"))
                    .font(.design(15, .bold))
                Text(tr("Everything this app and its child processes send is collected under it, deduplicated by domain and IP.", "Sheets"))
                    .font(.design(12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20.px)
            .padding(.top, 18.px)
            .padding(.bottom, 12.px)

            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                Text(tr("Running now", "Sheets").uppercased(with: localizer.locale))
                    .font(.design(10.5, .semibold))
                    .tracking(0.6 * UIScale.factor)
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 8.px)
                    .padding(.top, 2.px)
                    .padding(.bottom, 6.px)
                candidateList
                chooseAnother
            }
            .padding(.horizontal, 12.px)
            .padding(.bottom, 8.px)
            .disabled(working)

            footer
        }
        .frame(width: 520.px)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .interactiveDismissDisabled(working)
        .task { await load() }
        .alert(error: $failure) { _ in
            Button(tr("OK", "Sheets")) {}
        } message: { _ in
            Text(trf("Tidemark couldn't start monitoring %@.", "Sheets", selected?.name ?? ""))
        }
    }

    // MARK: Candidates

    @ViewBuilder
    private var candidateList: some View {
        if !loaded {
            HStack(spacing: 8.px) {
                ProgressView().controlSize(.small)
                Text(tr("Looking for running apps…", "Sheets"))
            }
            .font(.design(12))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 8.px)
            .padding(.vertical, 10.px)
        } else if candidates.isEmpty {
            Text(tr("Every running app is already monitored.", "Sheets"))
                .font(.design(12))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 8.px)
                .padding(.vertical, 10.px)
        } else {
            ScrollView {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(candidates) { candidate in
                        AddAppCandidateRow(candidate: candidate, isSelected: candidate.path == selection) {
                            selection = candidate.path
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: CGFloat(min(candidates.count, Self.visibleRows)) * (Self.rowHeight + Self.rowSpacing))
        }
    }

    private var chooseAnother: some View {
        HStack(spacing: 10.px) {
            Button(tr("Choose Another App…", "Sheets"), action: chooseApp)
                .buttonStyle(DesignButtonStyle(height: 26, cornerRadius: 7, horizontalPadding: 10))
                .fixedSize()
            Text(tr("The full path is saved to the database. Every Mac that has the same path starts monitoring it; Macs without it skip it.", "Sheets"))
                .font(.design(11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8.px)
        .padding(.top, 8.px)
        .padding(.bottom, 2.px)
    }

    // MARK: Footer

    /// Cancel on the fill and Start Monitoring on the accent, the design's 28 px buttons.
    private var footer: some View {
        HStack(spacing: 8.px) {
            if working {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.design(12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8.px)
            Button(tr("Cancel", "Sheets"), action: close)
                .buttonStyle(DesignButtonStyle(horizontalPadding: 12))
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button(tr("Start Monitoring", "Sheets"), action: start)
                .buttonStyle(DesignButtonStyle(kind: .accent, horizontalPadding: 12))
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || working)
        }
        .padding(.horizontal, 20.px)
        .padding(.vertical, 12.px)
        .frame(maxWidth: .infinity)
        .background(Theme.bg2)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    private var progressText: String {
        guard let selected, selected.pastRequests > 0 else { return tr("Starting…", "Sheets") }
        return trf("Backfilling %@ past requests…", "Sheets", Fmt.count(selected.pastRequests))
    }

    private var selected: AppCandidate? {
        candidates.first { $0.path == selection }
    }

    // MARK: Actions

    private func load() async {
        var list = AddAppCandidates.named(await model.capture.monitorCandidates())
        if let preselect = model.nav.addAppPreselect, !preselect.isEmpty {
            let path = AddAppCandidates.normalized(preselect)
            if !list.contains(where: { $0.path == path }) {
                list.insert(await candidate(for: path), at: 0)
            }
            selection = path
        }
        candidates = list
        if selection == nil { selection = list.first?.path }
        loaded = true
    }

    private func candidate(for path: String) async -> AppCandidate {
        let past = (try? await model.database.countRequests(inBundle: path)) ?? 0
        return AddAppCandidates.candidate(path: path, pastRequests: past)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose an App to Monitor", "Sheets")
        panel.prompt = tr("Choose", "Sheets")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = AddAppCandidates.normalized(url.path)
        if let existing = model.catalog.active.first(where: { AddAppCandidates.normalized($0.path) == path }) {
            // Already monitored: show it instead of adding it twice.
            model.nav.open(.app(existing.id), tab: .inventory)
            close()
            return
        }
        Task { @MainActor in
            let chosen = await candidate(for: path)
            candidates.removeAll { $0.path == path }
            candidates.insert(chosen, at: 0)
            selection = path
            loaded = true
        }
    }

    private func start() {
        guard let candidate = selected, !working else { return }
        working = true
        Task { @MainActor in
            do {
                let app = try await model.capture.monitorApp(path: candidate.path, includeChildren: true, alertOnDomain: true, alertOnIP: true, backfill: true)
                working = false
                model.nav.open(.app(app.id), tab: .inventory)
                close()
            } catch {
                working = false
                failure = error
            }
        }
    }

    private func close() {
        model.nav.showAddApp = false
        model.nav.addAppPreselect = nil
        dismiss()
    }
}

/// A radio row: app icon, name, bundle path and how many past requests would be backfilled.
private struct AddAppCandidateRow: View {
    var candidate: AppCandidate
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10.px) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.accent : Theme.ink3, lineWidth: 1.5.px)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 8.px, height: 8.px)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 16.px, height: 16.px)
                AppTile(identity: AddAppCandidates.identity(for: candidate), size: 28.px)
                // The name and the path stack at the window's line height, as in the design.
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.name)
                        .font(.design(12.5, .semibold))
                        .lineLimit(1)
                    Text(candidate.path)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8.px)
                // One line, whatever the language: the row's height is fixed.
                Text(AddAppCandidates.backfillLabel(candidate.pastRequests))
                    .font(.design(11))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8.px)
            .frame(maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 9.px, style: .continuous))
            .background(isSelected ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: 9.px, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Builds and labels "Monitor an App" candidates.
@MainActor
enum AddAppCandidates {
    /// Bundle path without a trailing slash.
    nonisolated static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// A candidate for a bundle chosen by hand (or preselected), named like every other screen names it.
    nonisolated static func candidate(path: String, pastRequests: Int64) -> AppCandidate {
        let bundle = Bundle(url: URL(fileURLWithPath: path))
        return AppCandidate(name: AppNaming.displayName(forBundlePath: path), path: path, bundleID: bundle?.bundleIdentifier, pastRequests: pastRequests)
    }

    /// Running apps renamed to their bundle's display name ("Visual Studio Code", not the process's "Code"), so
    /// the sheet uses the name the Requests table showed, sorted by that name.
    nonisolated static func named(_ candidates: [AppCandidate]) -> [AppCandidate] {
        candidates
            .map { candidate in
                var renamed = candidate
                renamed.name = AppNaming.displayName(forBundlePath: candidate.path)
                return renamed
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func identity(for candidate: AppCandidate) -> AppIdentity {
        AppIdentity(name: candidate.name, bundlePath: candidate.path, letter: String(candidate.name.prefix(1)), hue: nil, isMonitored: false, appID: nil)
    }

    /// `3,204 past requests` / `Nothing recorded yet`
    static func backfillLabel(_ count: Int64) -> String {
        switch count {
        case ..<1: tr("Nothing recorded yet", "Sheets")
        case 1: tr("1 past request", "Sheets")
        default: trf("%@ past requests", "Sheets", Fmt.count(count))
        }
    }
}
