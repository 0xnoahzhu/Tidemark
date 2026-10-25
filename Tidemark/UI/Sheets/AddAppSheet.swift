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

    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Monitor an App", "Sheets"))
                    .font(.system(size: 15, weight: .bold))
                Text(tr("Everything this app and its child processes send is collected under it, deduplicated by domain and IP.", "Sheets"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Running now", "Sheets").uppercased(with: localizer.locale))
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                candidateList
                chooseAnother
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .disabled(working)

            footer
        }
        .frame(width: 520)
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tr("Looking for running apps…", "Sheets"))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        } else if candidates.isEmpty {
            Text(tr("Every running app is already monitored.", "Sheets"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(candidates) { candidate in
                        AddAppCandidateRow(candidate: candidate, isSelected: candidate.path == selection) {
                            selection = candidate.path
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(candidates.count) * (Self.rowHeight + 2), 6 * (Self.rowHeight + 2)))
        }
    }

    private var chooseAnother: some View {
        HStack(spacing: 10) {
            Button(tr("Choose Another App…", "Sheets"), action: chooseApp)
                .fixedSize()
            Text(tr("The full path is saved to the database. Every Mac that has the same path starts monitoring it; Macs without it skip it.", "Sheets"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(tr("Cancel", "Sheets"), action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button(tr("Start Monitoring", "Sheets"), action: start)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selected == nil || working)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.accent : Theme.ink3, lineWidth: 1.5)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                AppTile(identity: AddAppCandidates.identity(for: candidate), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(candidate.path)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(AddAppCandidates.backfillLabel(candidate.pastRequests))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(isSelected ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
