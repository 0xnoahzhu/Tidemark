# Tidemark on macOS 27: feature adoption plan

Tidemark's deployment target is macOS 27.0, so the APIs in this plan need no `#available` checks. The plan adopts macOS 27 features, and the macOS 26 Liquid Glass features the app is built on, only where they help one of three goals:

- Tidemark uses less CPU while it runs all day.
- Tidemark is less likely to lose data.
- Tidemark feels more native.

Features that would only add decoration are left out, and section 7 explains why each one was rejected.

- **SDK.** macOS 27.0 SDK, Xcode 27.1 (27A9275), Swift 6.4 (swiftlang-6.4.0.34.1).
- **Inputs.** Parallel surveys of the SDK, built from `.swiftinterface` and header diffs against the macOS 26.5 SDK. They covered SwiftUI/SwiftUICore, AppKit, WebKit/Network/Foundation/Observation/System, Charts/UserNotifications/ServiceManagement/OSLog, FoundationModels, AppIntents/WidgetKit/CoreSpotlight/TipKit, and the Swift 6.4 toolchain with Xcode build settings.
- **Reviewed.** 2026-10-24, against the repository layout in `docs/ARCHITECTURE.md`.

**Status labels used below**

| Label | Meaning |
|---|---|
| Typechecked | The snippet, as printed here, compiles with `swiftc -typecheck -swift-version 6 -target arm64-apple-macos27.0` against the Xcode 27.1 SDK. It was checked with the upcoming features recommended in section 3 enabled: InferIsolatedConformances, NonisolatedNonsendingByDefault, MemberImportVisibility and ExistentialAny. Stubs for Tidemark types are omitted. Nothing was run. |
| Runtime-checked | A survey agent observed this behaviour on macOS 27 (Darwin 27). |
| Signature only | The signature was copied from the SDK interface but never compiled. Section 8 says what to check. |

---

## 1. Summary

### Adopt now, ordered by impact

| # | Feature | Key APIs (min macOS) | Where | Effort |
|---|---|---|---|---|
| 4.1 | No lost batch on quit, pause or sleep | `withTaskCancellationShield` (27), `withTaskCancellationHandler` `sending` overload (Swift 6.4), `.terminateLater` | `Database/WriteBuffer`, `Surge/SurgeCLIClient`, `App/AppDelegate` | S |
| 4.2 | Settings drive services without views | `withContinuousObservation`, `ObservationTracking.Token` (27) | new `App/ServiceWiring` | S |
| 4.3 | Sleep, wake and app launch/exit events | `NSWorkspace` typed messages (26), `NSApplication.DidChangeOcclusionStateMessage` (27) | new `App/SystemEvents`, `Capture/`, `Process/` | S |
| 4.4 | Live UI that backs off by itself | `systemPrefersReducedResourceUsage` (27), occlusion messages (27) | `LiveState` publishing, Requests table, charts, menu bar | M |
| 4.5 | Liquid Glass shell and glass-amount slider | `glassEffect`/`Glass`, `GlassEffectContainer`, `ToolbarSpacer`, `scrollEdgeEffectStyle`, `safeAreaBar`, `Slider` ticks (26); `ToolbarItemVisibilityPriority(lowerThan:)`, `contentMarginsRemoved` (27) | `UI/Shell`, `UI/Requests`, `UI/MenuBar`, `UI/Settings` | M |
| 4.6 | Site Probe on WebPage with a per-session proxy | `WebPage`/`WebView`, `NetworkListener`/`NetworkConnection` (26), `proxyConfigurations` (14); GPC, `alternateRequest`, `overrideReferrer`, `cookies(for:)`, `os_lockdown_mode_enabled` (27) | `Probe/`, `UI/SiteProbe` | L |
| 4.7 | Notifications that group and act | `threadIdentifier`, `interruptionLevel`, `relevanceScore`, action icons (12); `appEntityIdentifiers` (27) | `Capture/` notifier | S |
| 4.8 | ~~On-device host insights (opt-in)~~ Removed: the design has no place for them | `SystemLanguageModel`, `@Generable` (26); `LanguageModelError`, `variant`, `Error.assetsUnavailable` (27) | none | — |
| 4.9 | Fast waterfall and histograms | `RectanglePlot`/`BarPlot` (15), `chartXSelection(range:)` (14), conditional `ChartContent` (27) | `UI/SiteProbe`, Requests histogram, sparklines | M |
| 4.10 | macOS 27 controls | `.pickerStyle(.tabs)`, `.textFieldStyle(.bordered)` + `textInputBorderShape`, `alert(error:)` (27); `ButtonRole.confirm/.close` (26) | all pages, Settings, sheets | S |
| 4.11 | App Intents core | `allowedExecutionTargets`, `CustomAppIntentErrorConvertible`, lazy `DisplayRepresentation` image, `SyncableEntity` (27); `supportedModes` (26) | new `Intents/` in the app target | M |
| 4.12 | Export without blocking the UI | `fileExporter` + `WritableDocument` + `FileWrapperDocumentWriter` (27) | Domains & IPs, App detail | S |
| 4.13 | Launch at login | `SMAppService.mainApp` (13) | Settings > General, via 4.2 | S |

### Decisions

- **Concurrency settings.** Keep the default actor isolation at `nonisolated` and turn on Approachable Concurrency. Section 3 shows two compile errors you would get if the default were `MainActor`.
- **Pending rows.** Shutdown, recording pause and sleep each drain the write buffer inside a cancellation shield. If the drain fails, the rows go to the existing spool.
- **Settings changes.** Services are reconfigured through `withContinuousObservation`. A view's `onChange` would not work here, because it runs only while that view exists, and the menu-bar app often has no window open.
- **UI refresh rate.** The live UI slows down when the system asks it to or when nothing is visible. Capture, database writes and alerts never slow down.
- **Where glass goes.** Glass stays on the control layer: the sidebar, toolbar, menu-bar popover header and floating controls. The sidebar keeps the split view's own glass, and the glass slider tints that glass (`NSGlassEffectView.tintColor`, none at Clear) instead of laying `.clear` or tinted `.regular` glass over it, which stacks on the system glass (section 8, item 1).
- **Site Probe.** It moves to `WebPage` and `NetworkListener`. macOS 27 adds GPC, referrer and cache-bypass options, plus a hardened WebContent process.
- **Host insights.** Removed, with Foundation Models: the Tidemark design has no place for an explanation of a host (4.8). Private Cloud Compute was rejected before that.
- **Menu bar.** `MenuBarExtra` stays for now. A status item using the macOS 27 AppKit expanded-interface API is the planned upgrade (section 5.1).

---

## 2. Ground rules and SDK facts that shape the plan

- **Availability spelling.** The 27 SDK writes availability as `@available(anyAppleOS 27.0, *)` in Swift and `API_AVAILABLE(anyappleos(27.0))` in C. Grepping only for `macOS 27` misses most of the new Swift API, including all of Observation's 27 additions and about 93 SwiftUI declarations. Foundation's overlay writes `@available(macOS 27, ...)` with no `.0`.
- **No Swift Subprocess module ships in the SDK.** `surge-cli` keeps using `Foundation.Process` + `Pipe`, but reads the pipes through `readabilityHandler`-bridged `AsyncStream`s rather than `FileHandle.bytes.lines`: every `FileHandle.AsyncBytes` read is serialized through one shared I/O actor, so a long-running `watch` stalls every other reader, and byte-wise iteration measured about 700× slower (3.5 s against 5 ms for a 290 KB `dump recent`). Do not copy the `SurgeWatcher` example below as written.
- **WebKit 27 adds no API for observing subresource loads.** The Site Probe proxy is still the only way to get a complete host list. The macOS 27 additions in WebKit's SwiftUI overlay are visionOS-only, so `WebView` and `WebPage` remain macOS 26 APIs.
- **SwiftUI `MenuBarExtra` and `MenuBarExtraStyle` are unchanged in 27.** There is still no programmatic dismissal and no expanded-interface hook.
- **Liquid Glass has no continuous parameter.** `Glass` offers only `.regular`, `.clear`, `.identity`, `.tint(_:)` and `.interactive(_:)`.
- **No macOS 27 API changes** in UserNotifications (apart from one AppIntents cross-import property), ServiceManagement, OSLog, TipKit, Synchronization, NaturalLanguage, CoreML or `libproc.h`.
- **Network's macOS 27 additions do not matter here** (DTLS, QUIC/multiplex path callbacks, TCP pacing). The relevant APIs are the macOS 26 `NetworkListener`/`NetworkConnection`.
- **Several SwiftUI 27 additions do nothing on macOS.**
  - Unavailable on macOS: `CrossFadeNavigationTransition`, `sceneAccessory`, `toolbarOverflowMenu`, `ToolbarPlacement.statusBar`, `topBarPinnedTrailing`, `BackgroundTask.processingTask`.
  - `.automatic` is the only option on macOS: `toolbarMinimization*`, `presentationPlacement`, `TabSectionExpansion`.
  - Still unavailable on macOS: `AdaptableTabBarPlacement.sidebar`, even though a doc comment mentions it.
- **48 SwiftUICore lines with `@_originallyDefinedIn(module: "SwiftUI", macOS 27.0)` are moved declarations, not new API.**

---

## 3. Build settings

### 3.1 Recommended build setting changes

These settings live in `Tidemark.xcodeproj` (the project no longer uses XcodeGen). `SWIFT_STRICT_CONCURRENCY` has been removed and `ENABLE_PREVIEWS` turned on; the rest of the table is still open.

| Setting | Current | Recommended | Why |
|---|---|---|---|
| `SWIFT_VERSION` | `"6.0"` | keep `"6.0"` | Swift 6.4 accepts `-language-mode` 4, 4.2, 5 and 6 only. Swift 6 mode already gives full data-race errors. |
| `SWIFT_STRICT_CONCURRENCY` | removed | keep removed | It does nothing in Swift 6 mode: its xcspec condition applies only to 4, 4.2 and 5. |
| `SWIFT_APPROACHABLE_CONCURRENCY` | — | `YES` | In Swift 6 mode this adds InferIsolatedConformances and NonisolatedNonsendingByDefault. A probe build confirmed both flags are passed with `SWIFT_VERSION 6.0`. It is the Xcode 27 template default. |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | — (nonisolated) | keep `nonisolated` | See below. |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | `YES` | keep `YES` | Stops NIOCore and Logging members leaking through `import PostgresNIO`. It is the Xcode 27 template default and a Swift 7 feature. |
| `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY` | — | `YES` | Cheap now: the code base already writes `any SurgeClient`. It is a Swift 7 feature. |
| `ENABLE_PREVIEWS` (app target) | `YES` | keep `YES` | `#Preview` needs it. |
| `SWIFT_EMIT_LOC_STRINGS` (app target) | `NO` | keep `NO` | Strings go through `tr("key", "Table")` with runtime `String` keys, which compiler extraction cannot see. Extracting SwiftUI literals would only collect strings that skip the in-app language switch. |
| `STRING_CATALOG_GENERATE_SYMBOLS` | — | optional `YES` | Only worth it if `tr()` moves to generated `LocalizedStringResource` symbols, which turns a missing key into a compile error. First check that setting `resource.locale` honours the in-app language override (section 8). |
| `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO` | as is | keep | Tidemark spawns `surge-cli` and reads libproc data for other processes' PIDs. |
| `SWIFT_STRICT_MEMORY_SAFETY` | — | `NO` | The libproc and sockaddr code is legitimately pointer-heavy. At most, try `MIGRATE` once on `Process/`. |
| `ENABLE_ENHANCED_SECURITY` | — | `NO` for now | Optional arm64e hardening. Check first that SwiftNIO and PostgresNIO build for arm64e. |

**Why the default isolation stays `nonisolated`.** `Model/`, `Services/`, `Surge/`, `Database/`, `Process/` and `Capture/` value types are decoded, stored and queried inside actors. `State/` and `UI/` already say `@MainActor` explicitly, and SwiftUI views are `@MainActor` anyway. With `-default-isolation=MainActor`, two errors appeared:

- `main actor-isolated conformance of 'SurgeEvent' to 'Decodable' cannot be used in actor-isolated context [#IsolatedConformances]`. Runtime-checked by the toolchain survey.
- `#Predicate` over a model type fails with `KeyPath<…> does not conform to the 'Sendable' protocol`. Typechecked while preparing this plan.

If MainActor-by-default is wanted later, move `UI/` and `State/` into their own target and give only that target the MainActor default.

In Xcode build-setting terms the open recommendations are:

```
SWIFT_APPROACHABLE_CONCURRENCY = YES              // project level
SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY = YES      // project level
// SWIFT_DEFAULT_ACTOR_ISOLATION stays at its default (nonisolated)
```

Also update the "Conventions" line in `docs/ARCHITECTURE.md` to read "Swift 6 language mode (which implies complete strict concurrency), approachable concurrency, no warnings".

**Signing.** The project signs ad hoc (`CODE_SIGN_IDENTITY: "-"`, no team). Any capability that needs a provisioning profile is blocked until a team is set. That rules out time-sensitive notifications (4.7) and the App Group that a widget or Control extension would need (5.2, 5.3).

### 3.2 Code conventions that go with these settings

- **`@concurrent` for CPU-heavy nonisolated async helpers.** With NonisolatedNonsendingByDefault, a nonisolated `async` function runs on the caller's actor. Called from `@MainActor` code, it therefore runs on the main thread. Mark these `@concurrent` or move them into an actor: decoding JSON lines, libproc chain walks, public-suffix classification, CSV encoding and spool replay.

  ```swift
  @concurrent func decodeBatch(_ lines: [Data]) async throws -> [SurgeEvent] {
      let decoder = JSONDecoder()
      return try lines.map { try decoder.decode(SurgeEvent.self, from: $0) }
  }
  ```
- **Name every long-lived task**, so it shows up in Instruments and the debugger:
  - `Task(name:)` (back-deployed) for `surge-watch`, `write-buffer`, `alert-poller`, `egress-monitor` and `probe-<id>`.
  - `.task(id:name:priority:)` (26.4) for view-scoped work.
  - `task.name` (27) can be read back for a diagnostics row.
- **`Task.immediate(name:)` (26) for toggles.** UI state changes in the same frame, before the first suspension point.

  ```swift
  Toggle("Recording", isOn: Binding(get: { live.recording }, set: { on in
      Task.immediate(name: "toggle-recording") { await live.setRecording(on) }
  }))
  ```
- **`Mutex` (Synchronization, 15) for synchronous hot caches used off the main actor.** Examples are the `(pid, startTime)` chain cache and the per-app known-host sets. The 27 SDK adds nothing to Synchronization.
- **Previews.** Use `#Preview(_:traits:arguments:body:)` (27) to render state matrices: a request row that is OK, rejected, failed, active or IPv6, or a new-site alert. Never write `PreviewProvider`, which is deprecated in 27.

  ```swift
  #Preview("Request row", arguments: RequestRecord.samples) { request in
      RequestRow(request: request).frame(width: 640)
  }
  ```

Status: Typechecked (`Task.immediate`, `#Preview(arguments:)`, `.task(id:name:priority:)`).

---

## 4. Adopt now

### 4.1 Never lose the last batch: cancellation-safe shutdown

**APIs**
- `withTaskCancellationShield(operation:)`, async and sync forms (`_Concurrency`, macOS 27).
- `withTaskCancellationHandler(operation:onCancel:)`, the Swift 6.4 overload with typed throws and a `sending` `onCancel` closure. It is back-deployed.
- `NSApplicationDelegate.applicationShouldTerminate(_:)` returning `.terminateLater`, together with `reply(toApplicationShouldTerminate:)`.

**Where**
- `Database/WriteBuffer`: drain on quit, on pause and before sleep.
- `Surge/SurgeCLIClient`: child-process lifetime.
- `App/AppDelegate` and `AppBootstrap`, which needs a new `shutdown(_:) async`.

**Why.** Tidemark's promise is "every Surge request in PostgreSQL". The write buffer holds up to 200 rows or 1 second of data. When the owning tasks are cancelled (quit, recording paused, settings changed), PostgresNIO and `Task.sleep` see the cancellation and the final batch is dropped. Inside a shield, `Task.isCancelled` is false and child tasks start uncancelled, so the last `INSERT … ON CONFLICT` runs to completion. If it fails, the rows go to the disk spool. `applicationWillTerminate` is synchronous and cannot await, so the drain must happen in `applicationShouldTerminate` with `.terminateLater`.

The 6.4 `withTaskCancellationHandler` overload accepts a `sending` `onCancel` closure. That closure can capture the non-Sendable `Process` and terminate `surge-cli` when the watch task is cancelled, so no orphaned watcher outlives a reconnect.

```swift
actor WriteBuffer {
    func flush() async throws { /* multi-row INSERT … ON CONFLICT via PostgresNIO */ }
    func spoolPending() { /* append to ~/Library/Application Support/Tidemark/spool/ */ }

    /// Quit, "pause recording" and system sleep all end here.
    func drain() async {
        await withTaskCancellationShield {
            do { try await flush() } catch { spoolPending() }
        }
    }
}

actor SurgeWatcher {
    func run(executable: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--raw", "watch", "request", "request-update", "real-time-speed",
                             "environment", "reload", "shutdown"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        try await withTaskCancellationHandler {
            for try await line in pipe.fileHandleForReading.bytes.lines { _ = line /* decode + yield */ }
        } onCancel: {
            process.terminate()        // `sending` closure: capturing the non-Sendable Process is fine
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task(name: "shutdown") {
            await AppBootstrap.shutdown(model)   // stop surge-watch → drain WriteBuffer → close PostgresNIO
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

**Notes**
- **Order matters.** Stop ingesting first, then drain inside the shield, then cancel the PostgresNIO client's `run()` task. A shield does not help once the connection itself has been torn down.
- **Bound the drain** to about 3 seconds by racing it against a sleep, then spool. A hung database must not stop the user from quitting.
- `Task.hasActiveCancellationShield` (27) is for asserts and logging only.

Status: Typechecked. Shield semantics are Runtime-checked: inside the shield `isCancelled == false`, and afterwards it is `true` again.

### 4.2 Settings drive services without views: `withContinuousObservation`

**APIs.** `withContinuousObservation(options:apply:)`, `ObservationTracking.Options` (`.willSet`/`.didSet`/`.deinit`), `ObservationTracking.Event` (`kind`, `matches(_:)`) and the `~Copyable` `ObservationTracking.Token`. All are Observation, macOS 27.

**Where.** A new `App/ServiceWiring.swift`, owned by `AppBootstrap`. It turns `Preferences`, `AlertState` and `LiveState` changes into effects on services:
- Surge endpoint or database URL changes → reconnect.
- Batch preset changes → `WriteBuffer` configuration.
- `openAtLogin` → `SMAppService` (4.13).
- `showIn` → activation policy. `appearance` → `NSApp.appearance`. `language` → `Localizer`.
- Unread count → Dock badge.

**Why.** `Preferences` persists in `didSet`. The side effects belong in one place. They cannot live in a view's `.onChange`, because that runs only while the view exists, and Tidemark is often running with only the menu bar. `withContinuousObservation` re-arms itself, runs on the caller's actor, tracks exactly the properties its closure reads, and delivers changes made in the same turn as one event. The token stops it. This replaces hand-written `withObservationTracking` re-arm loops and Combine.

```swift
@MainActor
final class ServiceWiring {
    private var connection: ObservationTracking.Token?
    private var badge: ObservationTracking.Token?
    private var pendingReconnect: Task<Void, Never>?

    func start(_ model: AppModel) {
        let prefs = model.preferences
        connection = withContinuousObservation(options: [.didSet]) { [weak self] event in
            // Read every property that should trigger a reconnect *before* any early return:
            // only properties read in this closure are tracked.
            _ = (prefs.surgeEndpoint, prefs.databaseURL)
            guard event.kind != .initial, let self else { return }
            // Settings text fields write on every keystroke; reconnect once typing settles.
            pendingReconnect?.cancel()
            pendingReconnect = Task(name: "settings-reconnect") {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                model.capture.reconnect()
            }
        }
        badge = withContinuousObservation(options: [.didSet]) { _ in
            let unread = model.alerts.unreadCount
            NSApp.dockTile.badgeLabel = unread == 0 ? nil : unread.formatted()
        }
    }

    func stop() {
        connection.take()?.cancel()   // Token is ~Copyable: `connection?.cancel()` does not compile
        badge.take()?.cancel()
        pendingReconnect?.cancel()
    }
}
```

**Notes**
- `event.matches(\Preferences.surgeCLIPath)` tells you which property changed, so one observer can restart only `surge-cli` or only PostgreSQL. `matches` returns false for `.initial`.
- Do not write `guard event.matches(...) else { return }` before reading the properties. The closure then reads nothing and is never called again.
- When the consumer is an async loop, use `Observations({ ... })` (26) instead, for example a sampler that feeds `rateHistory`.

Status: Typechecked. Semantics are Runtime-checked by the toolchain survey: `.initial` arrives once, then one event per change transaction; only read properties are tracked; dropping the token stops delivery. The SDK has no doc comments for these APIs (section 8).

### 4.3 Sleep, wake, and app launch/exit through typed NotificationCenter messages

**APIs**
- `NSWorkspace` messages (macOS 26): `.willSleep`, `.didWake`, `.didLaunchApplication`, `.didTerminateApplication`, `.sessionDidResignActive` and `.sessionDidBecomeActive`. `.screensDidSleep` and `.screensDidWake` are `AsyncMessage`s.
- `NSApplication.DidChangeOcclusionStateMessage` (`.didChangeOcclusionState`, macOS 27). `NSWindow` has the same message.
- `NotificationCenter.addObserver(of:for:using:)`, which returns an `ObservationToken`.

**Where.** A new `App/SystemEvents.swift`. It feeds `CaptureEngine`, the `LibProcInspector` chain cache, the Process Tree and Monitored Apps "Running/Exited" state, and the egress monitor.

**Why**
- **Before sleep:** drain the write buffer (4.1) and record a gap marker, so multi-Mac timelines stay honest.
- **After wake:** restart the `surge-cli` watch, because the pipe often goes stale, and re-check egress IPs. `NWPathMonitor`, already in the architecture, covers network changes that happen while awake.
- **App launch and exit:** update the running state live instead of polling `isRunning(pid:startTime:)`, and evict chain-cache entries for exited PIDs. Correctness is already guaranteed by the `(pid, startTime)` key; this is about memory and freshness.
- **Typed messages:** the payloads are `@MainActor` typed, so there is no `userInfo` casting.

```swift
@MainActor
final class SystemEvents {
    private var workspaceTokens: [NotificationCenter.ObservationToken] = []
    private var appTokens: [NotificationCenter.ObservationToken] = []

    func start(_ capture: CaptureEngine, budget: UIBudget) {
        let ws = NSWorkspace.shared
        let center = ws.notificationCenter            // NSWorkspace posts here, not on .default
        workspaceTokens = [
            center.addObserver(of: ws, for: .willSleep) { _ in capture.prepareForSleep() },
            center.addObserver(of: ws, for: .didWake) { _ in capture.resumeAfterWake() },
            center.addObserver(of: ws, for: .didLaunchApplication) { msg in capture.appLaunched(msg.application) },
            center.addObserver(of: ws, for: .didTerminateApplication) { msg in capture.appTerminated(msg.application) },
        ]
        appTokens = [
            NotificationCenter.default.addObserver(of: NSApplication.shared, for: .didChangeOcclusionState) { _ in
                budget.appVisible = NSApplication.shared.occlusionState.contains(.visible)
            },
        ]
    }

    func stop() {
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        appTokens.forEach(NotificationCenter.default.removeObserver)
        workspaceTokens = []; appTokens = []
    }
}
```

**Notes**
- The system allows only a short window after `willSleep`. Keep the work to a drain plus a spool fallback.
- `Process.DidTerminateMessage` (26) is not needed for `surge-cli`, because the `events()` stream already ends when the child exits. Read `terminationStatus` there and reconnect with backoff, as the architecture already specifies.

Status: Typechecked. The AppKit survey also compiled its own launch/terminate snippet.

### 4.4 A live UI that backs off by itself

**APIs.** `EnvironmentValues.systemPrefersReducedResourceUsage` (SwiftUI, macOS 27) and the occlusion messages from 4.3 (macOS 27).

**Where**
- The coalescing interval at which `CaptureEngine` publishes rows into `LiveState`.
- The Requests `Table`, sparklines and histogram animations, and the `MenuBarExtra` popover.
- GeoIP/ASN/reverse-DNS prefetch for rows the user is not looking at.
- Egress polling while the page is visible.

**Why.** `request-update` arrives at about 100 events per second on a busy Mac. For an app that runs all day, re-rendering the UI is the main avoidable CPU cost. Two independent signals tell Tidemark to slow down: the system asks apps to use less (27), and nobody can see the window (occlusion). Only the UI's refresh rate and optional prefetch change. Ingestion, the write buffer, first-contact detection and notifications are never throttled, so no data is lost.

```swift
@MainActor @Observable
final class UIBudget {
    var systemPrefersReduced = false
    var appVisible = true
    /// How often CaptureEngine publishes coalesced rows to LiveState.
    var liveInterval: Duration { systemPrefersReduced || !appVisible ? .seconds(1) : .milliseconds(250) }
    var animatesCharts: Bool { !systemPrefersReduced && appVisible }
    var prefetchesLookups: Bool { !systemPrefersReduced }
}

/// The menu bar label is always rendered, so it is the one view that can always read the value.
struct MenuBarLabel: View {
    @Environment(UIBudget.self) private var budget
    @Environment(\.systemPrefersReducedResourceUsage) private var reduceResources
    var body: some View {
        Image(systemName: "water.waves")
            .onChange(of: reduceResources, initial: true) { _, reduce in
                budget.systemPrefersReduced = reduce   // cheap flag flip only
            }
    }
}
```

**Notes**
- The SDK docs warn against starting expensive work in reaction to this value. The handler above only flips a flag, and the engine decides the cadence.
- App-level occlusion counts the app as visible if any of its windows is visible. If an open Settings window keeps the main table busy, also observe `NSWindow.DidChangeOcclusionStateMessage` for the main window. This needs a small window-accessor view to get the `NSWindow`.
- When the budget says so, turn off chart animations, including `@Animatable` shapes if any are added.

Status: Typechecked.

### 4.5 Liquid Glass shell and the glass-amount slider

**APIs**
- macOS 26: `View.glassEffect(_:in:)`, `Glass` (`.clear`, `.regular.tint(_:)`), `GlassEffectContainer`, `glassEffectID(_:in:)`, `.buttonStyle(.glass)` / `.glassProminent`, `ToolbarSpacer`, `sharedBackgroundVisibility(_:)`, `scrollEdgeEffectStyle(_:for:)`, `safeAreaBar(edge:)`, `Slider(... ticks:)` with `SliderTick`, and `ButtonRole.confirm` / `.close`.
- macOS 26.1: `visibilityPriority(_:)` with `.low` / `.high`.
- macOS 27: `ToolbarItemVisibilityPriority(lowerThan:)` / `(higherThan:)` and `ToolbarContent.contentMarginsRemoved(_:)`.

**Where**
- The sidebar in `UI/Shell`.
- The main toolbar and the Requests table in `UI/Requests`.
- The popover header in `UI/MenuBar`.
- The glass slider in Settings > General.
- Sheet buttons in `UI/Sheets`.

**Why.** This is the look users see on every page, and it is the system's own material. Glass belongs only on the navigation and control layer. Table rows, inspector cards and charts stay on solid content backgrounds.

**Sidebar glass amount.** `Preferences.glass` runs from 0 (Clear) to 100 (Tinted), default 40. Superseded for the sidebar (section 8, item 1): a `glassEffect` or color background in the sidebar column lies over the split view's own glass and covers it, so the sidebar keeps the system glass and `SidebarGlassTint` sets that glass's `tintColor` to the design's glass color at `--glassA`, with no tint at Clear. The slider row:

```swift
struct GlassAmountRow: View {
    @Binding var amount: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Slider(value: $amount, in: 0...100) {
            Text(tr("Liquid Glass", "Settings"))
        } minimumValueLabel: {
            Text(tr("Clear", "Settings"))
        } maximumValueLabel: {
            Text(tr("Tinted", "Settings"))
        } ticks: {
            SliderTick(0.0)
            SliderTick(50.0)
            SliderTick(100.0)
        }
        .disabled(reduceTransparency)   // the system replaces glass then; say so in the footer
    }
}
```

**Main toolbar.** Use three glass groups. Recording stays visible longest, the live-rate pill fills its capsule edge to edge, and export and the inspector toggle are the first to move into overflow.

```swift
.toolbar {
    ToolbarItem { RecordingToggle() }
        .visibilityPriority(.high)

    ToolbarSpacer(.fixed)

    ToolbarItem { LiveRatePill() }                 // sparkline + "12/s", drawn to the capsule edge
        .contentMarginsRemoved()
        .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .high))

    ToolbarSpacer()

    ToolbarItemGroup { AppFilterMenu(); ExportButton() }
        .visibilityPriority(.low)

    ToolbarItem { InspectorToggle() }
        .visibilityPriority(.low)
}
```

**Requests table.** A hard scroll edge keeps fast-moving rows readable under the toolbar. The status strip sits in a `safeAreaBar`, so rows scroll under it with the system edge treatment.

```swift
Table(live.rows, selection: $selection) { /* columns */ }
    .scrollEdgeEffectStyle(.hard, for: .top)
    .safeAreaBar(edge: .bottom) {
        StatusStrip(today: live.todayCount, rate: live.rate, buffered: live.bufferedRows, scope: devices.scope)
    }
```

**Menu bar popover header.** When recording starts, the Record button morphs into a rate pill.

```swift
@Namespace private var glassNS

GlassEffectContainer(spacing: 10) {
    HStack(spacing: 10) {
        Button(live.recording ? "Pause" : "Record", systemImage: "record.circle", action: toggle)
            .buttonStyle(.glass)
            .glassEffectID("record", in: glassNS)
        if live.recording {
            Text("\(live.rate, format: .number.precision(.fractionLength(1))) req/s")
                .monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular.tint(.red.opacity(0.2)))
                .glassEffectID("rate", in: glassNS)
        }
    }
}
```

**Sheets.** In Add/Edit Monitored App, the Save button uses `Button("Save", role: .confirm)`. In the IP lookup sheet, the Done button uses `Button("Done", role: .close)`. The system then styles and places them.

**Floating actions.** Use `.glassProminent` for the primary action of a page, such as Site Probe "Probe". Use `.glass` for secondary actions, such as Egress "Refresh".

Status: Typechecked. Sidebar glass stacking is settled: the sidebar keeps the system glass and the slider tints it (section 8, item 1). The rest of the visual result is unverified.

### 4.6 Site Probe on WebPage with a per-session proxy

**APIs**
- macOS 26: `WebPage`, `WebView(_:)`, `WebPage.Configuration.websiteDataStore`, `WebPage.load(_:)` (an async sequence of `NavigationEvent`, which is `Hashable`), `WebPage.callJavaScript(_:arguments:in:contentWorld:)`, `WebPage.customUserAgent`, `WebPage.NavigationDeciding`, `NetworkListener<TCP>`, `NetworkConnection<TCP>` and `NWParametersBuilder`.
- macOS 26.4: `NavigationPreferences.securityRestrictionMode`.
- macOS 14: `WKWebsiteDataStore.proxyConfigurations` and Network's `ProxyConfiguration(httpCONNECTProxy:)`.
- macOS 27: `NavigationPreferences.isGlobalPrivacyControlEnabled`, `.alternateRequest` and `.overrideReferrer`; `WKHTTPCookieStore.cookies(for:)`; `os_lockdown_mode_enabled()`.

**Where**
- `Probe/`: the CONNECT proxy and probe controller. `ProbeActions.startProbe` already returns the loopback port.
- `UI/SiteProbe`: the web view, step markers and waterfall.

**Why**
- **The proxy is still required.** macOS 27 adds no API to observe subresource loads. Page loads also run in WebKit's networking service, not in a Tidemark child process, so parent-chain attribution cannot tie them to Tidemark. The per-session port is the reliable link, and it matches the "forwarder source port" design in `ARCHITECTURE.md`.
- **`WebPage` instead of a `WKWebView` wrapper.** It replaces the `NSViewRepresentable` and delegate plumbing with an `@Observable` page model. Its async navigation events drive the waterfall's step markers.
- **`NetworkListener.run` ties the proxy's lifetime to the probe task.** Cancelling the probe tears down the listener.
- **The macOS 27 navigation preferences enable three probe features:**
  - A "Send GPC" toggle: probe the same URL with and without Global Privacy Control and diff the host sets to see which third parties drop out.
  - A cache-bypassing main-document fetch on re-probe.
  - A referrer field, to see whether a site pulls in different third parties when the visitor arrives from a search engine.
- **Hardening.** Probes load arbitrary URLs, so the WebContent process should run with `.maximizeCompatibility`, which turns off the JIT and widens memory-tagging coverage.

```swift
struct ProbeDecider: WebPage.NavigationDeciding {
    var sendGPC: Bool
    var referrer: String?

    @MainActor mutating func decidePolicy(for action: WebPage.NavigationAction,
                                          preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        preferences.isGlobalPrivacyControlEnabled = sendGPC          // 27
        preferences.securityRestrictionMode = .maximizeCompatibility // 26.4
        preferences.overrideReferrer = referrer                      // 27
        if action.target?.isMainFrame == true {
            var request = action.request
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            preferences.alternateRequest = request                   // 27, main resource only
        }
        return .allow
    }
}

@MainActor
func makeProbePage(proxyPort: NWEndpoint.Port, store: WKWebsiteDataStore,
                   decider: ProbeDecider, userAgent: String?) -> WebPage {
    // Must be set before the first load starts.
    store.proxyConfigurations = [
        ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: proxyPort))
    ]
    var config = WebPage.Configuration()
    config.websiteDataStore = store                                  // WKWebsiteDataStore.nonPersistent()
    let page = WebPage(configuration: config, navigationDecider: decider)
    page.customUserAgent = userAgent                                 // ProbeDeviceMode desktop/mobile
    return page
}

@MainActor
func runProbe(_ page: WebPage, store: WKWebsiteDataStore, url: URL,
              mark: (WebPage.NavigationEvent) -> Void) async throws -> [[String: Any]] {
    for try await event in page.load(url) {
        mark(event)                                   // waterfall step markers
        if event == .finished { break }
    }
    // Per-resource timing to refine the CONNECT-level host bars.
    let raw = try await page.callJavaScript("""
        return performance.getEntriesByType('resource')
          .map(e => ({url: e.name, start: e.startTime, dur: e.duration, type: e.initiatorType}))
        """, contentWorld: .defaultClient)   // Swift name of WKContentWorld.defaultClientWorld
    let cookies = await store.httpCookieStore.cookies(for: url)       // 27: "Cookies set" column
    _ = cookies
    return raw as? [[String: Any]] ?? []
}

// View: WebView(page)
```

**The per-session CONNECT relay.** The relay forwards the client's CONNECT head to Surge's HTTP proxy unchanged. Surge itself answers `200 Connection established` and applies rules, policy and logging. The relay only records the head and pipes bytes in both directions.

```swift
struct ConnectRelay: Sendable {
    let surgePort: NWEndpoint.Port                       // from `dump event` / http-listen, usually 6152
    let record: @Sendable (_ connectHead: Data) -> Void
    let log = Logger(subsystem: "io.tidemark.Tidemark", category: "probe-proxy")

    static func makeListener() throws -> NetworkListener<TCP> {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)   // loopback only
        return try NetworkListener(using: .parameters(initialParameters: params) { TCP() })
    }

    func serve(_ listener: NetworkListener<TCP>) async throws {
        try await listener.run { client in
            do { try await relay(client) } catch { log.debug("tunnel closed: \(error)") }
        }
    }

    private func relay(_ client: NetworkConnection<TCP>) async throws {
        var head = Data()
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {         // a head may span several reads
            let (chunk, meta) = try await client.receive(atMost: 16_384)
            head.append(chunk)
            if meta.endOfStream || head.count > 64 * 1024 { throw ProbeProxyError.malformedRequest }
        }
        record(head)
        let upstream = NetworkConnection(to: .hostPort(host: "127.0.0.1", port: surgePort)) { TCP() }
        try await upstream.send(head)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await pump(from: client, to: upstream) }
            group.addTask { try await pump(from: upstream, to: client) }
            try await group.waitForAll()
        }
    }

    private func pump(from source: NetworkConnection<TCP>, to sink: NetworkConnection<TCP>) async throws {
        while true {
            let (data, meta) = try await source.receive(atMost: 65_536)
            try await sink.send(data, endOfStream: meta.endOfStream)
            if meta.endOfStream { return }
        }
    }
}
```

**Lockdown Mode.** Call `os_lockdown_mode_enabled()` (`import Darwin`, macOS 27) once when a probe starts and cache the result. If Lockdown Mode is on, show this banner: "Lockdown Mode is on: some web features are disabled, so the host list may differ." WebKit then forces `.lockdown` and ignores weaker restriction modes. Per the header, the call aborts the process if querying fails unexpectedly.

**Notes**
- **Startup order:** start the listener, wait for `.ready` and read its port, set `proxyConfigurations` on a fresh `nonPersistent()` store, create the `WebPage`, then load.
- **Resource Timing** keeps only 250 entries by default. Raise the limit at document start (`performance.setResourceTimingBufferSize`). Cross-origin entries without `Timing-Allow-Origin` still have `startTime` and `duration`.
- **`willSubmit(formInfo:)`** (27) can add a "form POST to X" marker on the timeline. Never store `formValues`, which may contain credentials.

Status: Typechecked. Runtime behaviour is unverified (section 8).

### 4.7 Notifications that group and act

**APIs**
- `UNMutableNotificationContent.threadIdentifier`, `interruptionLevel` and `relevanceScore` (macOS 12).
- `UNNotificationAction(identifier:title:options:icon:)` with `UNNotificationActionIcon(systemImageName:)` (12).
- `UNMutableNotificationContent.appEntityIdentifiers` (macOS 27, from the UserNotifications × AppIntents cross-import overlay).

**Where.** The notifier in `Capture/`, plus the `UNUserNotificationCenterDelegate` in `App/`.

**Why**
- **Grouping.** `threadIdentifier` set to the app ID groups alerts per monitored app in Notification Center. This complements the existing "one notification per app per 30 s" burst grouping.
- **Actions.** "Show Requests" opens the alert's requests. Tidemark has no mutes, so there is no "Mute Host" action.
- **Ranking.** `relevanceScore` ranks a new site above a new host above a new IP in the notification summary.
- **Entities.** `appEntityIdentifiers` tells Siri, Shortcuts and Apple Intelligence which `MonitoredAppEntity` the alert is about (4.11).

```swift
func alertContent(_ alert: AlertItem, app: MonitoredApp) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = trf("%@ reached a new site", "Notifications", app.name)
    content.body = alert.value
    content.threadIdentifier = app.id.uuidString
    content.categoryIdentifier = "newHost"
    content.interruptionLevel = .active
    content.relevanceScore = alert.scope == .site ? 1 : (alert.scope == .host ? 0.6 : 0.3)
    content.appEntityIdentifiers = [EntityIdentifier(for: MonitoredAppEntity.self, identifier: app.id)]  // 27
    return content
}

let open = UNNotificationAction(identifier: "open", title: tr("Show Requests", "Notifications"),
                                options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "list.bullet"))
center.setNotificationCategories([UNNotificationCategory(identifier: "newHost", actions: [open],
                                                         intentIdentifiers: [], options: [])])
```

**Notes**
- `.timeSensitive` needs the time-sensitive notifications capability, which needs a signing team. Leave it off until the project signs with a team. After that, offer it only for scope `site`.
- `appEntityIdentifiers` has no doc comment in the SDK. It is harmless if the system ignores it.

Status: Typechecked. In the snippet, `AlertItem` scope names and `trf` follow the repository.

### 4.8 On-device host insights (removed)

**Status: removed.** Tidemark no longer uses Foundation Models. The Tidemark design has no place for an explanation of a host, so the Requests inspector's About this host section and the notification line went first; the `Insight/` module (`HostInsightService` and its generator), `HostInsightProviding`, `HostInsight`, `HostContext`, `HostCategory` and the database methods that read and wrote `host_insights` followed once nothing could reach them. The `host_insights` table stays in the schema, unused, because migrations are never edited. The rest of this section records the plan as it was.

**APIs**
- FoundationModels, macOS 26: `SystemLanguageModel.default` (`availability`, `isAvailable`, `supportsLocale(_:)`), `LanguageModelSession(model:instructions:)`, `respond(to:generating:options:)`, `@Generable` (including enums) and `@Guide`.
- macOS 27: `SystemLanguageModel.variant.displayName` ("AFM 3 Core" / "AFM 3 Core Advanced"), `LanguageModelError`, `SystemLanguageModel.Error.assetsUnavailable` and `LanguageModelSession.Error.concurrentRequests`.
- `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`, the `samplingMode` spelling, is back-deployed.

**Where.** The repository defined `HostInsightProviding`, `HostInsight`, `HostContext`, `HostCategory` and the `host_insights` table keyed by `(host, language)`, and this item implemented them. All but the table are gone (see the status above).

**Why.** Surge already supplies the facts: IPs, ASN and organisation, policy, first seen, request count. The model turns them into a category and one sentence, for example "AI inference API operated by Anysphere". That is useful as a second line under a new-site alert. Because the cache is shared in Postgres, each host is classified once across all Macs.

```swift
@Generable
enum GeneratedCategory: String {   // mirrors HostCategory
    case aiInference = "ai-inference", api, cdn, telemetry, analytics, ads, auth, update, storage, messaging, media, web, unknown
}

@Generable(description: "What a network host contacted by a macOS app is for")
struct GeneratedInsight {
    var category: GeneratedCategory
    @Guide(description: "Company or service that most likely operates the host; empty if unknown")
    var operatorName: String
    @Guide(description: "One or two short sentences on what the host is used for")
    var summary: String
    @Guide(description: "Optional privacy or security note; empty if none")
    var concern: String
}

actor InsightGenerator {
    /// One short-lived session per request; callers go through this actor, so requests never overlap.
    func generate(facts: String, chinese: Bool) async throws -> (GeneratedInsight, model: String)? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let rule = chinese && model.supportsLocale(Locale(identifier: "zh-Hans"))
            ? "Answer in Simplified Chinese." : "Answer in English."
        let session = LanguageModelSession(model: model, instructions: """
            You explain why a macOS app contacts a network host. Use only the facts given. \
            If unsure, use category unknown. \(rule)
            """)
        do {
            let response = try await session.respond(
                to: facts, generating: GeneratedInsight.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160))
            return (response.content, model.variant.displayName)   // stored in host_insights.model
        } catch let error as LanguageModelError {
            switch error {
            case .rateLimited(let info): throw InsightError.retry(after: info.resetDate)
            case .guardrailViolation, .refusal: return nil         // store as unclassified, don't retry
            case .unsupportedLanguageOrLocale: return try await generate(facts: facts, chinese: false)
            default: throw error
            }
        } catch SystemLanguageModel.Error.assetsUnavailable {
            return nil                                             // Apple Intelligence was turned off
        }
    }
}
```

**Rules**
- Insights run on-device only. Not adopted as planned: Settings have no Notifications tab or switch for insights, and notifications never carry them, since the design shows neither.
- In the UI they are labelled "Generated on this Mac" and phrased as "likely". They never affect first-contact detection or alerts.
- Never delay an alert waiting for a model response.
- Background requests use non-streaming `respond`; the SDK docs say this reduces `rateLimited` errors.
- Facts go in the prompt from `HostContext`. Do not use tools: they add latency and gain nothing, because Tidemark already has the facts.
- The answer language follows `Localizer.shared.languageCode` (the in-app language), not `Locale.current`.
- Track live availability by reading the observable `SystemLanguageModel.default.availability`, either in the view or through 4.2. This keeps `isAvailable` and `unavailableReason` current.

Status: Typechecked, including the `@Generable` enum. Model quality and capabilities can only be judged at runtime.

### 4.9 A fast waterfall and histograms

**APIs**
- Charts: vectorized `RectanglePlot` and `BarPlot` (15), and `chartXSelection(range:)` (14).
- macOS 27: `EmptyView` and `_ConditionalContent` now conform to `ChartContent`, and `Chart`/`ChartContent` use `@ContentBuilder`.

**Where**
- The Site Probe waterfall.
- The Requests histogram.
- Sparklines in the toolbar, menu bar and app detail page.

**Why**
- **Vectorized plots.** One `RectanglePlot` draws hundreds of host bars from a single collection, which is much cheaper than `ForEach` with individual marks.
- **No selection on the Requests histogram.** The design draws it as a plain row of bars with axis labels, so it has no range selection, hover callout or highlighted bar under the pointer.
- **Shared mark helpers (27).** A plain `@ViewBuilder` function can return `some ChartContent` with `if`/`switch`/`EmptyView`. The histogram, sparkline and waterfall can share mark helpers. The survey confirmed this compiles for 27 and is rejected for 26.

```swift
Chart {
    RectanglePlot(probe.hosts, xStart: .value("Start", \.start), xEnd: .value("End", \.end), y: .value("Host", \.host))
}
.chartXSelection(range: $selectedWindow)

@ViewBuilder
func rateMarks(_ buckets: [Bucket], highlight: Date?) -> some ChartContent {
    ForEach(buckets) { b in
        BarMark(x: .value("Time", b.id, unit: .minute), y: .value("Requests", b.count))
    }
    if let highlight { RuleMark(x: .value("Selected", highlight)) }
}
```

Status: Typechecked. The survey typechecked `rateMarks`.

### 4.10 macOS 27 controls

**APIs (SwiftUI, macOS 27)**
- `PickerStyle.tabs` (`TabsPickerStyle`).
- `TextFieldStyle.bordered` (`BorderedTextFieldStyle`) with `View.textInputBorderShape(_:)` (`.capsule`, `.roundedRectangle`, `.automatic`).
- `View.alert(error:actions:)` and `alert(error:actions:message:)` bound to `Binding<E?>`.

**Where and why**
- **`.tabs` is only for pickers that switch views:** Domains/IPs in Domains & IPs; Current/History/Lookup on Egress IP; inspector sections; Waterfall/Hosts in Site Probe. It reads as tab navigation, and VoiceOver announces it as tabs. Value filters (All/Alerts/Blocked, time range) stay `.segmented`.
- **`.bordered` with a border shape** is for fields inside content and Settings: DB host/port/user, `surge-cli` path and the Egress lookup field. `RoundedBorderTextFieldStyle` is deprecated in 27. The Requests search stays `.searchable` in the toolbar.
- **`alert(error:)`** replaces "isPresented + stored error" pairs. It covers Settings "Test connection", migration failures, probe listener bind errors and IP lookup failures. `DatabaseError` is already `LocalizedError`, so the title comes from `errorDescription`.

```swift
Picker("Inventory", selection: $kind) {
    Text(tr("Domains", "Inventory")).tag(HostKind.domain)
    Text(tr("IPs", "Inventory")).tag(HostKind.ip)
}
.pickerStyle(.tabs)
.labelsHidden()

Form { /* DB host, port, user, surge-cli path … */ }
    .textFieldStyle(.bordered)
    .textInputBorderShape(.roundedRectangle)

SettingsDatabasePane(onError: { dbError = $0 })
    .alert(error: $dbError) { _ in
        Button(tr("Retry", "Settings")) { model.capture.reconnect() }
        Button(tr("Cancel", "Settings"), role: .cancel) {}
    } message: { error in
        Text(error.recoverySuggestion ?? "")
    }
```

Status: Typechecked. How `.tabs` looks on macOS still needs a visual check.

### 4.11 App Intents core, in the app target

**APIs**
- macOS 15: `AppEntity`, `EntityQuery`, `SetValueIntent`.
- macOS 26: `AppIntent.supportedModes` / `IntentModes`. It replaces `openAppWhenRun`, which is deprecated.
- macOS 27:
  - `AppIntent.allowedExecutionTargets` / `IntentExecutionTargets` and `EntityQuery.allowedExecutionTargets`.
  - `CustomAppIntentErrorConvertible` and `AppIntentError(description:)`.
  - `DisplayRepresentation(title:subtitle:synonyms:image:)` with a lazy async image.
  - `EntityQuery.displayRepresentations(for:)`.
  - `SyncableEntity`.

**Where.** A new `Intents/` folder in the app target, with `MonitoredAppEntity` and `SetRecordingIntent`. An `AppShortcutsProvider` can add phrases such as "Pause Tidemark recording".

**Why**
- **Shortcuts automation.** For example, "pause recording on a personal hotspot".
- **Entity IDs.** Notifications need entity identifiers (4.7).
- **Groundwork for later.** A Control or widget can reuse these intents (5.2, 5.3).
- **macOS 27 extras:**
  - `allowedExecutionTargets [.main]` keeps recorder intents in the process that owns `surge-cli` and PostgresNIO, even after the intents move into a shared package.
  - Typed errors give clear, localized failures.
  - App icons are rendered lazily, only when Shortcuts or Spotlight shows them.
  - `SyncableEntity` fits because entity IDs are shared Postgres UUIDs, identical on every Mac.

```swift
struct MonitoredAppEntity: AppEntity, SyncableEntity {
    var id: AppID                       // row in the shared `apps` table: same on every Mac
    var name: String
    var bundlePath: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Monitored App"
    static let defaultQuery = MonitoredAppQuery()

    var displayRepresentation: DisplayRepresentation {
        let path = bundlePath
        return DisplayRepresentation(title: "\(name)") {            // built only when shown
            let icon = NSWorkspace.shared.icon(forFile: path)
            guard let tiff = icon.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            return .init(data: png)
        }
    }
}

struct MonitoredAppQuery: EntityQuery {
    static var allowedExecutionTargets: IntentExecutionTargets { [.main, .widgetKitExtension] }
    func entities(for identifiers: [AppID]) async throws -> [MonitoredAppEntity] { /* CatalogState */ [] }
    func displayRepresentations(for identifiers: [AppID]) async throws -> [AppID: DisplayRepresentation] {
        [:] /* names only; no full rows */
    }
}

struct SetRecordingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Recording"
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }  // owns surge-cli + PostgresNIO
    static let supportedModes: IntentModes = .background
    @Parameter(title: "Recording") var value: Bool
    func perform() async throws -> some IntentResult {
        await Recorder.setRecording(value)
        return .result()
    }
}

enum TidemarkIntentError: Error, CustomAppIntentErrorConvertible {
    case surgeNotRunning, databaseUnreachable
    var appIntentError: AppIntentError {
        switch self {
        case .surgeNotRunning: AppIntentError(description: "Surge is not running.")
        case .databaseUnreachable: AppIntentError(description: "Tidemark can't reach its PostgreSQL database.")
        }
    }
}
```

Status: Typechecked. `Recorder` stands for whatever reaches `AppModel.capture` from an intent.

### 4.12 Export without blocking the UI

**APIs.** `View.fileExporter(isPresented:document:contentType:defaultFilename:onCompletion:onCancellation:)` for `WritableDocument`, plus `FileWrapperDocumentWriter` (SwiftUI, macOS 27). The `FileDocument` and `ReferenceFileDocument` exporter overloads are deprecated.

**Where.** The Domains & IPs export and the App detail inventory export. Requests has no export: the design shows none. The snippet below uses a request query only to show the pattern.

**Why.** SwiftUI takes a snapshot on the main actor, which here is just the `Sendable` filter. It then runs the writer in the background with coordinated file access, so the CSV or NDJSON query against PostgreSQL never blocks the UI.

```swift
/// Not @MainActor: a main-actor class fails the WritableDocument conformance check
/// ("crosses into main actor-isolated code" [#ConformanceIsolation]).
final class RequestExportDocument: WritableDocument, Sendable {
    static let writableContentTypes: [UTType] = [.commaSeparatedText]
    let filter: RequestQuery                        // Sendable snapshot of what is on screen
    init(filter: RequestQuery) { self.filter = filter }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<RequestQuery> {
        FileWrapperDocumentWriter(configuration) { filter, _ in
            FileWrapper(regularFileWithContents: try await RequestCSVExporter.csv(for: filter))
        }
    }
    func snapshot(contentType: UTType) async throws -> sending RequestQuery { filter }
}

.fileExporter(isPresented: $isExporting, document: exportDocument,
              contentType: .commaSeparatedText, defaultFilename: "tidemark-requests.csv") { result in
    if case .failure(let error) = result { exportError = error }
}
```

**Notes.** The survey's version marked the class `@MainActor` and does not compile; the version above does. `FileWrapper(regularFileWithContents:)` holds the whole file in memory, so this is off the main thread but not streaming. For very large exports, see section 8.

Status: Typechecked (corrected version).

### 4.13 Launch at login

**APIs.** `SMAppService.mainApp` with `register()`, `unregister()`, `status` and `openSystemSettingsLoginItems()` (macOS 13). ServiceManagement has no 26 or 27 changes.

**Where.** The `Preferences.openAtLogin` toggle in Settings > General, applied through 4.2.

**Why.** A recorder that does not start after a reboot misses data. The `.requiresApproval` status needs its own row, with a button that opens Login Items.

```swift
@MainActor func applyOpenAtLogin(_ on: Bool) throws {
    let service = SMAppService.mainApp
    if on {
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        else if service.status != .enabled { try service.register() }
    } else if service.status == .enabled {
        try service.unregister()
    }
}
```

**Notes.** `Preferences.openAtLogin` defaults to `true`. Registering shows the system's "login item added" notice, so register only after the first explicit confirmation, for example at the end of onboarding.

Status: Typechecked.

---

## 6. macOS 27 behaviour changes to account for

These are not features to adopt, but they change how existing code behaves or which spelling to use.

- **Menu item images are hidden.** The 27 doc for `NSMenuItem.image` says AppKit "will typically hide images". Check every menu: the app-filter menu with app icons, command menus and context menus. Accept the new default for decorative icons. On AppKit `NSMenuItem`s whose image carries information, set `preferredImageVisibility = .visible` (macOS 27). The SDK has no SwiftUI equivalent, so check SwiftUI `Menu`s visually.
- **`NSOpenPanel` derives `canChooseFiles` and `canChooseDirectories` from `allowedContentTypes`.** In the "Add Monitored App" picker, set `[.applicationBundle]` and do not override the flags afterwards. `fileImporter` wraps this.
- **Result builders are unified.** `ContentBuilder` is a typealias for `ViewBuilder`. `toolbar`, `commands` and `accessibilityRotor` take `@ContentBuilder`, and Charts accepts conditionals. Existing `@ViewBuilder` code is unaffected.
- **`Shape`, `GeometryEffect` and `ShapeView` are now `nonisolated` protocols.** A sparkline or histogram `Shape`'s `path(in:)` must not touch main-actor state. `_RemoveGlobalActorIsolation` is deprecated: annotate with `nonisolated` instead.
- **`NSStatusItem.view`, `target` and `action` are no longer deprecated.** This matters for 5.1.
- **`SystemLanguageModel.contextSize` returns the real value on 27.** It was hard-coded to 4096 on 26.0 through 26.3, so size prompts from it (Tidemark no longer uses Foundation Models, see 4.8).

---

## 5. Later / optional

Each entry lists the APIs, what it would give Tidemark, and what should trigger adopting it.

### 5.1 AppKit status item with an expanded-interface session (replaces `MenuBarExtra`)

**APIs**
- macOS 27: `NSStatusItemExpandedInterfaceDelegate`, `NSStatusItem.expandedInterfaceDelegate`, `NSStatusItem.expandedInterfaceSession`, `NSStatusItemExpandedInterfaceSession.cancel()` and `NSGlassEffectView.effectIsInteractive`.
- `NSStatusItem.view`, no longer deprecated in 27.

**What it gives.** The popover takes part in menu-bar keyboard navigation and menu tracking, like a system menu. Buttons such as "Open Tidemark" and "Settings…" can close it reliably with `session.cancel()`, which `MenuBarExtra` still cannot do in 27. An optional live rate view can sit in the menu bar through `item.view = NSHostingView(...)`. The panel can host the existing `MenuBarPanel` SwiftUI view on an `NSGlassEffectView` whose `style` and `tintColor` follow the glass slider.

**Trigger.** Adopt this when the dismissal or keyboard-navigation gaps in `MenuBarExtra(.window)` become user-visible, or when a live menu-bar sparkline is wanted.

**Gotchas**
- The delegate protocol is not main-actor isolated. Conform with `@MainActor NSStatusItemExpandedInterfaceDelegate`, an isolated conformance.
- The begin callback is named `statusItem(_:didBegin:)` in Swift.
- Do not set `item.menu` or button `target`/`action` when using the delegate.

The AppKit survey typechecked this pattern.

```swift
@MainActor
final class StatusItemController: NSObject, @MainActor NSStatusItemExpandedInterfaceDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
    override init() { super.init(); item.expandedInterfaceDelegate = self }
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        guard let button = statusItem.button, let window = button.window else { return }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrameTopLeftPoint(NSPoint(x: r.minX, y: r.minY)); panel.orderFrontRegardless()
    }
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) { panel.orderOut(nil) }
    func dismissFromInside() { item.expandedInterfaceSession?.cancel() }
}
```

### 5.2 Control Center / menu bar recording control

**APIs.** `ControlWidget`, `StaticControlConfiguration`, `ControlWidgetToggle`, `ControlValueProvider` and `ControlCenter.shared.reloadControls(ofKind:)` (macOS 26), plus `allowedExecutionTargets` (27).

**What it gives.** A recording toggle for users who hide Tidemark's own menu-bar item.

**Cost.** A widget extension and an App Group, which needs a signing team. The value comes from a shared flag that the app writes, never from a Postgres connection inside the extension. `SetRecordingIntent` (4.11) already declares `[.main]`, so the toggle drives the real recorder.

### 5.3 Desktop widget, including `.systemExtraLargePortrait`

**APIs.** `WidgetFamily.systemExtraLargePortrait` (macOS 27), which was unavailable on macOS in 26, and `IntentWidgetFamily.systemExtraLargePortrait`.

**What it gives.** A tall "Today" column showing the latest new-site alerts per app, the request count and a rate sparkline.

**Cost.** Same extension and App Group as 5.2. The app writes a small snapshot to the group container and calls `WidgetCenter.reloadTimelines(ofKind:)`. Write widget previews with `#Preview(as:widget:timeline:)`, because `WidgetPreviewContext` / `previewContext` is deprecated in 27.

### 5.4 Spotlight, search-in-app and selection awareness

**APIs**
- macOS 27: `IndexedEntityQuery` (`reindexEntities`, `reindexAllEntities` with `CSSearchableIndexDescription`), `CSSearchableItem(appEntity:) async`, `@DeferredProperty(indexingKey:)`, `@AppIntent(schema: .system.searchInApp)` (`.system.search` is deprecated) and `EntityCollection<Entity>`.
- macOS 15.4: `View.appEntityIdentifier(forSelectionType:identifier:)`.
- macOS 26: interactive `SnippetIntent`.

**What it gives**
- Typing `api2.cursor.sh` in Spotlight opens Domains & IPs.
- "Search Tidemark for…" filters Requests.
- Siri understands the selected Table row as a host.
- An intent such as "Open these hosts" can take hundreds of IDs without loading the rows.
- A "Today's new hosts" snippet has an inline Open button.

**Trigger.** Adopt once `HostEntity` exists. Index only inventory hosts, never individual requests.

### 5.5 Favicons

**APIs.** `AsyncImage(request:scale:content:placeholder:)` and `View.asyncImageURLSession(_:)` (macOS 27).

**What it gives.** Site icons in Domains & IPs and Notifications.

**Why not now.** Tidemark itself would contact every host the monitored apps reached, including trackers and suspicious hosts. That pollutes its own log and leaks the user's activity to those hosts.

**If adopted**
- Default off.
- Fetch the registrable domain only, and only for visible rows.
- Use one ephemeral session with a fixed user agent (typechecked below).
- Tag that traffic as Tidemark's own.
- Turn it off while `UIBudget.prefetchesLookups` is false.

```swift
static let faviconSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 5
    c.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 32 << 20)
    return URLSession(configuration: c)
}()
// AsyncImage(request: URLRequest(url: …, cachePolicy: .returnCacheDataElseLoad)) { … } placeholder: { … }
//     .asyncImageURLSession(Self.faviconSession)
```

### 5.6 Drag Monitored Apps between Monitoring and Archived

**APIs.** `DynamicViewContent.reorderable(collectionID:)`, `View.reorderContainer(for:in:isEnabled:move:)` and `ReorderDifference` (macOS 27).

**What it gives.** Dragging an app into the sidebar's Archived section archives it. With collection IDs, one gesture covers both reordering and archiving. Attribution does not depend on list order, because the nearest monitored bundle in the chain wins. A reorder inside a single `List` is already covered by `.onMove`, so this is only worth it for moves between sections.

SwiftUI ships no helper that applies a `ReorderDifference` to your data. This generic one is typechecked:

```swift
extension Array where Element: Identifiable {
    mutating func apply<C>(_ d: ReorderDifference<Element.ID, C>) {
        let moving = d.sources.compactMap { id in first { $0.id == id } }
        removeAll { d.sources.contains($0.id) }
        switch d.destination.position {
        case .before(let id): insert(contentsOf: moving, at: firstIndex { $0.id == id } ?? endIndex)
        case .end: append(contentsOf: moving)
        }
    }
}
```

### 5.7 Smaller options

| Option | APIs (min macOS) | Use in Tidemark |
|---|---|---|
| Trackpad zoom and pointer brush in the waterfall | `GestureInputKinds`, `MagnifyGesture(…inputKinds: .indirectTouch)`, `DragGesture(…inputKinds: .pointer)` (27) | Only if `chartXSelection(range:)` is not enough. |
| Swipe actions in the Notifications list | `swipeActions(edge:allowsFullSwipe:content:onPresentationChanged:)`, `swipeActionsContainer()` (27) | "Mark read" on a row; pause live insertion while a row's actions are open. |
| Composable filters and rules | `Predicate(all:)`, `Predicate(any:)` (27) | When notification rules become user-defined and must be stored (`Predicate` is Codable). The Requests filter compiles to SQL today. |
| Progress for long jobs | `ProgressManager`, `Subprogress` (27, Observable, Sendable) | Backfill, inventory rebuild, first migration of a shared database, large exports. |
| Concentric corners | `ConcentricRectangle`, `containerShape` (26); `GeometryProxy.concentricCornerRadii` (27) | `Card` and `TimingBar` corners concentric with the inspector and window. |
| Diagnostics pane | `Task.name` (27), `OSLogStore(scope: .currentProcessIdentifier)` (12), `Logger` `.secondsSince1970` format (26) | "Copy diagnostics": `surge-cli` restarts, batch errors, attribution misses. |
| `surge-cli` path validation | `FilePath.stat()`, `Stat.type`, `.permissions` (System, 27) | Typed `Errno` messages in Settings > Surge. |
| Debuggable probe timing script | `WKContentWorld(configuration:)` with `isInspectable` (27) | Develop the Resource Timing collector in Web Inspector. |
| Other Tidemark Macs on the LAN | `NetworkBrowser<Bonjour>` (26) | Live "recording" presence. The shared Postgres database stays the source of truth. |
| First-run tips | TipKit `popoverTip`, `TipGroup`, `Tips.Event(donationLimit:)` (26; no 27 changes) | The glass slider, Add Monitored App, and the Site Probe proxy explainer. |
| Hero imagery | `backgroundExtensionEffect()` (26) | Only if a hero image is added, for example a probe snapshot header. Never on the Table or `WebView`. |

---

## 7. Considered and not adopted

| Item | Reason |
|---|---|
| `PrivateCloudComputeLanguageModel` (27) | Needs a managed entitlement and sends hostnames and app names off-device, which a privacy-monitoring tool should not do by default. |
| `SpotlightSearchTool` (27) | Tidemark's data lives in PostgreSQL, not Spotlight. Prompt facts (4.8) or a custom Tool fit better. |
| Tools on the insight session | The facts are already in `HostContext`. Tools add latency and nondeterminism. |
| `URLSessionConfiguration.proxyConfigurations`, `NetworkConnection.establishmentReport()` for egress | Egress uses `surge-cli test-policy-external-ip` / `test-policy` with line hashes, per the architecture. |
| `Process.DidTerminateMessage` for `surge-cli` | The `events()` stream already ends on exit. |
| `TabView(.sidebarAdaptable)` + `TabContent.help` (27) | NavigationSplitView fits a three-pane monitor. `AdaptableTabBarPlacement.sidebar` is unavailable on macOS. |
| AppKit-only 27 controls: `NSRefreshController`, `NSSegmentedControl.role`, `NSToolbarItemGroup.role`, `NSControl.Events`, `NSViewCornerConfiguration`, `NSScrollView` live-scroll messages, `NSScreen.touchCapabilities`, `NSBackgroundExtensionView` | SwiftUI covers each of these: `.refreshable`, `.tabs`, SwiftUI toolbars, `ConcentricRectangle`, `backgroundExtensionEffect`. Reconsider them only for AppKit surfaces such as 5.1. |
| SwiftUI 27 additions that are unavailable or automatic-only on macOS | See section 2. |
| WebKit immersive-environment APIs (27) | visionOS only. |
| `LongRunningIntent` (27) | macOS imposes no background time limit on intents. |
| `WidgetPushHandler` (26) | No server component. |
| `SMAppService.agent(plistName:)` | No separate helper process. |
| Noncopyable `Continuation` / `withContinuation` (27) | It cannot be consumed inside escaping callbacks. Tidemark's bridges are escaping, so `CheckedContinuation` stays. |
| `FileDescriptor.pipe(options:)` (27) | Only needed with `posix_spawn`. `Process` + `Pipe` is used. |
| Span iteration, `ByteOrder` loads, `InlineArray` ring buffers, `isTriviallyIdentical` (27 / 6.4) | Possible micro-optimisations with no measured need. |

**Deprecated in the 27 SDK; never use in new code**
- **SwiftUI and previews:**
  - `PreviewProvider`, `PreviewDevice`, `previewLayout`, `previewDisplayName`, `previewContext` / `WidgetPreviewContext`.
  - `RoundedBorderTextFieldStyle`.
  - The `FileDocument` / `ReferenceFileDocument` `fileExporter` overloads.
  - The non-builder `mask(_:)`.
  - `_RemoveGlobalActorIsolation`.
- **App Intents:** `openAppWhenRun`; `@AssistantIntent`, `@AssistantEntity` and `@AssistantEnum` (use `@AppIntent(schema:)` and its siblings); `.system.search`.
- **FoundationModels:** `GenerationOptions.sampling` (use `samplingMode`) and `LanguageModelSession.GenerationError` (use `LanguageModelError`). `SystemLanguageModel.Adapter` and `init(adapter:)` are obsoleted.
- **AppKit:** `NSPanGestureRecognizer.numberOfTouchesRequired`, and `NSResponder` `begin`/`endGesture(with:)`, which are to be deprecated.

---

## 8. Verify before relying on

These findings are uncertain, or their signatures typecheck but their behaviour is undocumented. Check each one before building on it.

1. **Sidebar glass stacking (4.5).** On macOS 26 and 27 the NavigationSplitView sidebar is already system glass, and adding `glassEffect` inside it may stack two layers. If it does, keep the Clear end as the untouched system sidebar and apply only a tint layer above it (`Color.accentColor.opacity(t * 0.25)`). Also check:
   - `Theme.inkGlass` legibility at `.clear` on bright wallpapers.
   - That Reduce Transparency and Increase Contrast take over cleanly.

   Checked on macOS 27.0.1: the sidebar column is one full-height `NSGlassEffectView` (corner radius 0) under the traffic lights, in SwiftUI and AppKit alike; `NSSplitViewItem`'s private `wantsFloatingAppearance` returns NO and its setter does nothing, so there is no floating, inset pane. A color laid over the column covers that glass, so Tidemark lays nothing there and tints the glass itself: `SidebarGlassTint` finds the glass among the sidebar content's ancestors (`_NSSplitViewItemViewWrapper › NSGlassEffectView › … › NSHostingView`) and sets its public `tintColor` to the design's glass color at `--glassA`, with no tint at the Clear end. Window captures (`screencapture -l`) showed:
   - In an active window the tinted glass takes the color at that alpha: at Tinted (.92), 242,242,246 in light mode and 42,42,46 in dark mode, against 253 and 64,63,61 untinted. Tidemark itself could not be brought to the front from the test session, so this was measured on an AppKit split view sidebar in a key, non-activating panel.
   - In an inactive window the system draws tinted glass desaturated and nearer mid-gray: in light mode 243 untinted, 231 at the default 40 and 219 at Tinted; in dark mode 44, 56 and 66.
   - AppKit did not reset the tint: it stayed through key and main changes, appearance changes and hiding and showing the sidebar, and the dynamic color followed the appearance.
   - These captures leave out what lies behind the window, so they cannot show how much of the desktop the tinted glass lets through.

   Still unchecked: the `Theme.inkGlass` legibility and the Reduce Transparency and Increase Contrast items above.
2. **`withContinuousObservation` has no SDK documentation (4.2).** The survey's runtime checks covered the initial event, per-transaction coalescing and read tracking. Re-check after each SDK update, and add a unit test that toggles two properties in one turn and expects one event.
3. **Site Probe proxy coverage (4.6).** Compare a probe's recorded hosts against Surge's own log for the same session. Check that:
   - cleartext `http://` loads also arrive as `CONNECT`. If they arrive as absolute-form requests (`GET http://…`), the relay must handle them.
   - HTTP/3/QUIC is not used, or falls back to TCP, while a proxy is configured.
   - WebSockets are covered.
   - `requiredLocalEndpoint` really binds the listener to loopback only.
   - A thrown error inside the per-connection handler does not stop `NetworkListener.run`. The snippet catches errors there defensively.
4. **Resource Timing buffer (4.6).** Find the supported way to run a document-start script on `WebPage` that raises `performance.setResourceTimingBufferSize`. Until then, expect at most 250 entries per page.
5. **`systemPrefersReducedResourceUsage` (4.4).** The SDK does not say when the system sets it. Test with Low Power Mode and under thermal pressure, and confirm that capture throughput does not change while it is set.
6. **App-level occlusion (4.4).** Confirm that `NSApplication.DidChangeOcclusionStateMessage` fires when the last visible window is covered or minimised, and when the app is hidden.
7. **`.pickerStyle(.tabs)`, `contentMarginsRemoved()` and `visibilityPriority` (4.5, 4.10).** These typecheck, but their macOS appearance and overflow order need a visual check in a narrow window.
8. **`scrollEdgeEffectStyle(.hard, for: .top)` on `Table` (4.5).** Confirm it applies to the column-header region.
9. **`appEntityIdentifiers` (4.7).** There is no doc comment and the system behaviour is unknown. It is harmless if ignored.
10. **Time-sensitive notifications (4.7).** These need a signing team. Confirm the entitlement before enabling `.timeSensitive`.
11. **WritableDocument export (4.12).**
    - `FileWrapperDocumentWriter` needs a full `FileWrapper`, so `FileWrapper(regularFileWithContents:)` holds the whole CSV in memory.
    - For large exports, check whether returning `FileWrapper(url:)` for a temporary file written incrementally avoids reading it all into memory, or whether a custom `DocumentWriter` with `Destination == URL` can stream.
    - Remember that the survey's `@MainActor` version does not compile.
12. **FoundationModels at runtime (4.8).** No longer applies: host insights were removed.
13. **`NSStatusItemExpandedInterfaceDelegate` (5.1).** It is compiled only. Panel positioning on multiple displays, focus behaviour and how it interacts with `NSApp.setActivationPolicy(.accessory)` are unverified.
14. **Localisation with generated symbols (section 3.1).** Before switching `tr()` to generated `LocalizedStringResource` symbols, confirm that resolving a resource with `resource.locale = Localizer.shared.locale` picks the `zh-Hans` table even when the system language is English.
15. **The 27 SDK writes `anyAppleOS` availability.** When checking whether an API exists on macOS, grep for both `anyAppleOS 27` and `macOS 27`. Otherwise you will wrongly conclude many APIs are missing.
