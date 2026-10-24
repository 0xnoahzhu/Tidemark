import Foundation
import os

/// Runs site probes: opens a per-session loopback proxy that forwards to Surge, publishes the live
/// waterfall into `model.probe`, and saves finished sessions. Implements `ProbeActions`.
///
/// Surge and the database are read from `model` on every use, so clients the capture engine rebuilds are
/// picked up automatically.
@MainActor
final class ProbeController: ProbeActions {
    let model: AppModel
    /// Shared with the capture engine's pipeline, which adds the remote IPs Surge saw.
    let registry: ProbeRegistry
    /// The page counts as loading for this long (matches the design's status line).
    let loadingWindow: Duration
    /// Surge records of the last connections can trail the stop by a moment.
    let stopGrace: Duration

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "probe")

    private var server: ProbeProxyServer?
    private var refreshTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var publishedVersion = 0

    init(model: AppModel, registry: ProbeRegistry, loadingWindow: Duration = .milliseconds(6500), stopGrace: Duration = .seconds(1)) {
        self.model = model
        self.registry = registry
        self.loadingWindow = loadingWindow
        self.stopGrace = stopGrace
    }

    /// Loads saved sessions, newest first.
    func loadSessions() async {
        do {
            let sessions = try await model.database.probeSessions(limit: 100)
            model.probe.sessions = sessions
            if model.probe.selectedID == nil { model.probe.selectedID = sessions.first?.id }
        } catch {
            Self.log.error("Loading probe sessions failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: ProbeActions

    func startProbe(url: String, mode: ProbeDeviceMode, tail: Bool) async throws -> UInt16 {
        if model.probe.isRunning { await stopProbe() }
        let normalized = Self.normalizedURL(url)
        guard let host = URL(string: normalized)?.host(percentEncoded: false), !host.isEmpty else {
            throw URLError(.badURL)
        }
        let surge = model.surge
        let surgePort = (try? await CaptureTimeout.run(.seconds(5)) { try await surge.httpProxyPort() }) ?? 6152
        let server = ProbeProxyServer(upstreamPort: UInt16(clamping: surgePort), registry: registry)
        let id = UUID()
        let startedAt = Date.now
        registry.begin(sessionID: id, startedAt: startedAt)
        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            registry.end()
            throw error
        }
        self.server = server
        publishedVersion = 0

        let first = ProbeStep(at: 0, label: mode == .iphone ? "Page load · iPhone" : "Page load", url: normalized)
        model.probe.running = ProbeSession(
            id: id, deviceID: CaptureDeviceInfo.recordingDeviceID(model.preferences), url: normalized, host: host.lowercased(),
            mode: mode, startedAt: startedAt, endedAt: nil, steps: [first], hosts: []
        )
        model.probe.phase = .loading
        model.probe.proxyPort = port
        model.probe.selectedID = id

        // The page counts as loaded after the loading window; with `tail` off it still records until Stop,
        // the window only changes the status.
        let window = tail ? loadingWindow : min(loadingWindow, .seconds(3))
        phaseTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self, self.model.probe.running?.id == id else { return }
            self.model.probe.phase = .recording
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return port
    }

    func recordStep(label: String, url: String?) {
        guard var running = model.probe.running else { return }
        running.steps.append(ProbeStep(at: Date.now.timeIntervalSince(running.startedAt), label: label, url: url))
        registry.setStep(running.steps.count - 1)
        model.probe.running = running
    }

    @discardableResult
    func stopProbe() async -> ProbeSession? {
        guard var session = model.probe.running else { return nil }
        refreshTask?.cancel()
        phaseTask?.cancel()
        server?.stop()
        server = nil

        session.endedAt = .now
        session.hosts = registry.snapshot().hosts
        model.probe.running = nil
        model.probe.phase = .idle
        model.probe.proxyPort = nil
        model.probe.sessions.removeAll { $0.id == session.id }
        model.probe.sessions.insert(session, at: 0)
        model.probe.selectedID = session.id

        // Let the last Surge records (and their resolved IPs) arrive before closing the session.
        try? await Task.sleep(for: stopGrace)
        if registry.snapshot().sessionID == session.id {
            session.hosts = registry.end().hosts
            if let index = model.probe.sessions.firstIndex(where: { $0.id == session.id }) {
                model.probe.sessions[index] = session
            }
        }

        let database = model.database
        do {
            try await database.saveProbeSession(session)
        } catch {
            Self.log.error("Saving probe session failed: \(error.localizedDescription, privacy: .public)")
        }
        let sources = Self.sources(for: session)
        if !sources.isEmpty {
            do {
                try await database.touchHostSources(sources)
            } catch {
                Self.log.error("Recording probe hosts failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return session
    }

    func deleteProbe(_ id: UUID) async {
        model.probe.sessions.removeAll { $0.id == id }
        if model.probe.selectedID == id { model.probe.selectedID = model.probe.sessions.first?.id }
        do {
            try await model.database.deleteProbeSession(id)
        } catch {
            Self.log.error("Deleting probe session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    private func publish() {
        let snapshot = registry.snapshot()
        guard snapshot.version != publishedVersion, var running = model.probe.running, snapshot.sessionID == running.id else { return }
        publishedVersion = snapshot.version
        running.hosts = snapshot.hosts
        model.probe.running = running
    }

    /// Global-inventory rows for every host and IP a probe touched (`probe:<id>`, `Probe · <host>`).
    static func sources(for session: ProbeSession) -> [HostSourceTouch] {
        let path = "probe:\(session.id.uuidString.lowercased())"
        let title = "Probe · \(session.host)"
        let seen = session.endedAt ?? .now
        var result: [HostSourceTouch] = []
        for host in session.hosts {
            let kind: HostKind = HostName.isIPAddress(host.host) ? .ip : .domain
            result.append(HostSourceTouch(kind: kind, value: host.host, deviceID: session.deviceID, sourcePath: path, sourceTitle: title,
                                          appID: nil, bundlePath: nil, seenAt: seen, requestDelta: Int64(host.requestCount), geo: nil))
            for ip in host.ips where ip != host.host {
                result.append(HostSourceTouch(kind: .ip, value: ip, deviceID: session.deviceID, sourcePath: path, sourceTitle: title,
                                              appID: nil, bundlePath: nil, seenAt: seen, requestDelta: Int64(host.requestCount), geo: nil))
            }
        }
        return result
    }

    /// Adds `https://` when the user typed a bare host.
    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }
}
