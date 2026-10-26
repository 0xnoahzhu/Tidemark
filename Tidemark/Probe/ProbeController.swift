import Foundation
import os

/// Why a site probe cannot start. `errorDescription` is already in the app language.
struct ProbeStartError: Error, LocalizedError, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// Surge reports no HTTP proxy listener.
        case httpProxyOff
        /// Surge's HTTP proxy listener could not be read.
        case httpProxyUnknown
    }

    var reason: Reason
    var message: String

    var errorDescription: String? { message }
}

/// Runs site probes: opens a per-session loopback proxy that forwards to Surge, publishes the live
/// waterfall into `model.probe`, and saves finished sessions. Implements `ProbeActions`.
///
/// Surge and the database are read from `model` on every use, so clients the capture engine rebuilds are
/// picked up automatically. The proxy forwards to Surge's HTTP listener, and Surge's records are matched to
/// the probe by the forwarder's source port.
@MainActor
final class ProbeController: ProbeActions {
    let model: AppModel
    /// Shared with the capture engine's pipeline, which adds the remote IPs Surge saw.
    let registry: ProbeRegistry
    /// Fallback when the web view never reports the end of its first load: the page then counts as loaded
    /// after this long.
    let loadingTimeout: Duration
    /// With `tail` on, the probe keeps recording at least this long after the first page load finished
    /// ("Keep recording 6 s after load"): a Stop pressed earlier waits for the rest of it, so late requests
    /// of the page are still caught.
    let tailWindow: Duration
    /// Surge records of the last connections can trail the stop by a moment.
    let stopGrace: Duration
    /// Longest wait for each database write of a probe stopped because Tidemark quits.
    let quitSaveTimeout: Duration = .seconds(2)

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "probe")
    private static let table = "ProbeEngine"

    private var server: ProbeProxyServer?
    private var refreshTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var tailTask: Task<Void, Never>?
    private var tailEnabled = false
    private var publishedVersion = 0
    /// The stop in progress (closing, the grace for late records, the save). Every caller awaits the same one;
    /// it clears itself when done.
    private var stopping: (id: UUID, task: Task<ProbeSession?, Never>)?
    private var graceTask: Task<Void, Never>?
    /// Tidemark is quitting: no tail, no grace, bounded saves.
    private var quitting = false

    init(model: AppModel, registry: ProbeRegistry, loadingTimeout: Duration = .seconds(30), tailWindow: Duration = .seconds(6),
         stopGrace: Duration = .seconds(1)) {
        self.model = model
        self.registry = registry
        self.loadingTimeout = loadingTimeout
        self.tailWindow = tailWindow
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
        let listener = try await httpListener(of: surge)
        let server = ProbeProxyServer(upstreamPort: UInt16(clamping: listener.port), registry: registry, upstreamHost: listener.connectHost)
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
        tailEnabled = tail
        tailTask = nil

        let first = ProbeStep(at: 0, label: mode == .iphone ? "Page load · iPhone" : "Page load", url: normalized)
        model.probe.running = ProbeSession(
            id: id, deviceID: model.preferences.thisDeviceID, url: normalized, host: host.lowercased(),
            mode: mode, startedAt: startedAt, endedAt: nil, steps: [first], hosts: []
        )
        model.probe.phase = .loading
        model.probe.proxyPort = port
        model.probe.selectedID = id

        // The web view reports the end of the first load (`pageDidFinishLoading`); this only covers a page
        // that never reports it. Recording runs until Stop either way.
        phaseTask = Task { [weak self, loadingTimeout] in
            try? await Task.sleep(for: loadingTimeout)
            guard !Task.isCancelled, let self, self.model.probe.running?.id == id, self.model.probe.phase == .loading else { return }
            self.model.probe.phase = .recording
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.publish()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return port
    }

    func pageDidFinishLoading() {
        guard let running = model.probe.running, model.probe.phase == .loading else { return }
        phaseTask?.cancel()
        phaseTask = nil
        model.probe.phase = .recording
        guard tailEnabled else { return }
        let id = running.id
        tailTask = Task { [weak self, tailWindow] in
            try? await Task.sleep(for: tailWindow)
            guard let self, self.model.probe.running?.id == id else { return }
            self.tailTask = nil
        }
    }

    func recordStep(label: String, url: String?) {
        guard var running = model.probe.running else { return }
        running.steps.append(ProbeStep(at: Date.now.timeIntervalSince(running.startedAt), label: label, url: url))
        registry.setStep(running.steps.count - 1)
        model.probe.running = running
    }

    @discardableResult
    func stopProbe() async -> ProbeSession? {
        await stopProbe(quitting: false)
    }

    /// Stops the probe and saves it. A stop already in progress (Stop, then Quit) is awaited rather than
    /// skipped, so its save still happens before Tidemark exits. `quitting` skips the rest of the tail and the
    /// grace for late Surge records (also for a stop already in progress) and bounds the database writes.
    @discardableResult
    func stopProbe(quitting: Bool) async -> ProbeSession? {
        if quitting {
            self.quitting = true
            tailTask?.cancel()
            graceTask?.cancel()
        }
        var previous: ProbeSession?
        while let stopping { previous = await stopping.task.value }
        // Nothing (else) is running: the stop that was in progress, if any, saved the probe.
        guard model.probe.running != nil else { return previous }
        let id = UUID()
        let task = Task { () -> ProbeSession? in
            let session = await self.performStop()
            if self.stopping?.id == id { self.stopping = nil }
            return session
        }
        stopping = (id, task)
        return await task.value
    }

    private func performStop() async -> ProbeSession? {
        // Keep recording until the tail after the first load has passed.
        if let tailTask {
            await tailTask.value
            self.tailTask = nil
        }
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
        if !quitting {
            let grace = Task { [stopGrace] () -> Void in try? await Task.sleep(for: stopGrace) }
            graceTask = grace
            await grace.value
            graceTask = nil
        }
        if registry.snapshot().sessionID == session.id {
            session.hosts = registry.end().hosts
            if let index = model.probe.sessions.firstIndex(where: { $0.id == session.id }) {
                model.probe.sessions[index] = session
            }
        }

        let database = model.database
        let saved = session
        await write("Saving probe session") { try await database.saveProbeSession(saved) }
        let sources = Self.sources(for: session)
        if !sources.isEmpty {
            await write("Recording probe hosts") { try await database.touchHostSources(sources) }
        }
        return session
    }

    /// One database write of a stop. While quitting an unreachable server must not hold the process, so each
    /// write then gets `quitSaveTimeout`.
    private func write(_ label: String, _ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            if quitting {
                try await CaptureTimeout.unstructured(quitSaveTimeout, operation)
            } else {
                try await operation()
            }
        } catch {
            Self.log.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    /// Where Surge's HTTP proxy listens. Fails with a clear reason instead of guessing `127.0.0.1:6152`.
    private func httpListener(of surge: any SurgeClient) async throws -> SurgeHTTPListener {
        do {
            return try await CaptureTimeout.run(.seconds(8)) {
                if let detailed = surge as? any SurgeClientDetails { return try await detailed.httpProxyListener() }
                let port = try await surge.httpProxyPort()
                return SurgeHTTPListener(interface: "127.0.0.1", port: port)
            }
        } catch is SurgeHTTPProxyOff {
            throw ProbeStartError(
                reason: .httpProxyOff,
                message: tr("Surge's HTTP proxy is off. Turn on its HTTP proxy (http-listen) to run a probe.", Self.table)
            )
        } catch {
            let raw = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Self.log.error("Reading Surge's HTTP proxy listener failed: \(raw, privacy: .public)")
            throw ProbeStartError(reason: .httpProxyUnknown,
                                  message: trf("Couldn't find Surge's HTTP proxy port: %@", Self.table, Self.listenerFailure(error)))
        }
    }

    /// Why Surge's HTTP proxy listener could not be read, short and in the UI language. Surge's own message
    /// stays as Surge wrote it, a surge-cli that printed none is named by its exit status; the full English
    /// description goes to the log.
    static func listenerFailure(_ error: any Error) -> String {
        switch error {
        case is CaptureTimeoutError, SurgeError.timedOut: tr("Surge did not answer in time", table)
        case SurgeError.cliNotFound: tr("surge-cli was not found", table)
        case SurgeError.commandFailed(_, let message):
            if let status = SurgeError.exitStatus(inFailureMessage: message) {
                trf("surge-cli failed with exit status %lld", table, Int(status))
            } else {
                trf("surge-cli failed: %@", table, message)
            }
        case SurgeError.decoding: tr("Surge's answer could not be read", table)
        default: tr("An unexpected error occurred", table)
        }
    }

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
