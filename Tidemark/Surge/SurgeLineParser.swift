import Foundation

/// Classifies the lines of `surge-cli --raw watch request request-update real-time-speed dns environment reload shutdown`.
///
/// Events carry no name: surge-cli prints each event's payload as one JSON object per line, so lines are
/// told apart by their keys.
/// * `{"result":"Event subscribed"}` → `.subscribed`
/// * an object with `id` and `remoteHost` or `URL` → `.request` (`request` and `request-update` share the shape)
/// * an object with `in`, `out` and a speed history → `.speed`
/// * an object with `domain`, `server` and `data` but no `id` → `.dns`
/// * environment keys (`ProxyMode`, `ProxyGroupSelection`, …) or an `environment` event name → `.environmentChanged`
/// * a `reload` / `shutdown` key or event name → `.reload` / `.shutdown`
///
/// The payloads of `environment`, `reload` and `shutdown` could not be observed without changing Surge's
/// state, so those three are recognized by distinctive keys and anything else falls back to `.other(line)`.
enum SurgeLineParser {
    /// Top-level keys that only Surge's environment dictionary uses.
    static let environmentKeys: Set<String> = [
        "environment", "ProxyMode", "ProxyGroupSelection", "AllProxyModePolicyNameKey", "AutoPolicyGroupOverride",
        "MitMEnabled", "RewriteEnabled", "ScriptingEnabled", "SGEnvironmentCellularModeEnabledKey",
    ]

    static func event(from line: Data) -> SurgeEvent {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(KeyProbe.self, from: line) else { return .other(text(line)) }
        let keys = probe.keys
        let name = probe.eventName?.lowercased()

        if let result = probe.result, result.localizedCaseInsensitiveContains("subscribed") {
            return .subscribed
        }
        if keys.contains("id"), keys.contains("remoteHost") || keys.contains("URL") {
            guard let request = try? decoder.decode(SurgeRequest.self, from: line) else { return .other(text(line)) }
            return .request(SurgeOutputParser.normalized(request))
        }
        if keys.contains("in"), keys.contains("out"), keys.contains("downloadSpeedHistory") || keys.contains("uploadSpeedHistory") {
            guard let speed = try? decoder.decode(SurgeSpeed.self, from: line) else { return .other(text(line)) }
            return .speed(speed)
        }
        if !keys.contains("id"), keys.contains("domain"), keys.contains("server"), keys.contains("data") {
            guard let answer = try? decoder.decode(SurgeDNSEvent.self, from: line) else { return .other(text(line)) }
            return .dns(answer)
        }
        if name == "environment" || !keys.isDisjoint(with: environmentKeys) {
            return .environmentChanged
        }
        if name == "reload" || keys.contains("reload") || keys.contains("reloaded") {
            return .reload
        }
        if name == "shutdown" || keys.contains("shutdown") {
            return .shutdown
        }
        return .other(text(line))
    }

    static func event(from line: String) -> SurgeEvent {
        event(from: Data(line.utf8))
    }

    private static func text(_ line: Data) -> String {
        String(decoding: line, as: UTF8.self)
    }

    /// Top-level keys of a JSON object plus the few string values used to name events.
    private struct KeyProbe: Decodable {
        var keys: Set<String>
        var result: String?
        var eventName: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            keys = Set(container.allKeys.map(\.stringValue))
            result = try? container.decodeIfPresent(String.self, forKey: AnyKey("result"))
            eventName = ["event", "event-name", "name"].lazy
                .compactMap { try? container.decodeIfPresent(String.self, forKey: AnyKey($0)) }
                .first
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
