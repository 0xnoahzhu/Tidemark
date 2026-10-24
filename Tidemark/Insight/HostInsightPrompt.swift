import Foundation
import FoundationModels

/// Instructions, prompt and generation options for host insights.
enum HostInsightPrompt {
    /// Greedy sampling keeps answers stable (every Mac sees the same explanation); the verdict is short.
    static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 320)

    /// System instructions for one session. `languageCode` is `en` or `zh-Hans`.
    static func instructions(languageCode: String) -> String {
        var lines = [
            "You classify network hosts that apps on a Mac contacted, for a developer reviewing the Mac's traffic.",
            "Use only the facts provided and general knowledge of well-known companies and services. Never invent details.",
            "The host may be an IP address; then rely on the network owner and the app.",
            "Be brief: the summary is at most two short sentences.",
            "If you are not sure what the host is for, use the category unknown and say that it is not a well-known service.",
            "Leave the concern empty unless the host is clearly used for tracking, advertising, analytics or telemetry.",
        ]
        if languageCode == "zh-Hans" {
            lines.append("Write the operator name, summary and concern in Simplified Chinese. Keep company and product names in their usual form.")
        } else {
            lines.append("Write in English.")
        }
        return lines.joined(separator: "\n")
    }

    /// The facts Tidemark observed about the host, one per line.
    static func facts(for context: HostContext) -> String {
        var lines = ["Host: \(context.host)"]
        if let port = context.port { lines.append("Port: \(port)") }
        if let app = nonEmpty(context.appName) { lines.append("App: \(app)") }
        if let process = nonEmpty(context.processName), process != context.appName { lines.append("Process: \(process)") }
        let ips = context.ips.filter { !$0.isEmpty && $0 != context.host }
        if !ips.isEmpty { lines.append("IP addresses: \(ips.prefix(4).joined(separator: ", "))") }
        if let geo = context.geo, let network = nonEmpty(geo.display) { lines.append("Network: \(network)") }
        if let policy = nonEmpty(context.policy) { lines.append("Proxy policy: \(policy)") }
        if let firstSeen = context.firstSeen {
            lines.append("First seen: \(firstSeen.formatted(.iso8601.year().month().day()))")
        }
        if let count = context.requestCount { lines.append("Requests so far: \(count)") }
        lines.append("Explain this host.")
        return lines.joined(separator: "\n")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
