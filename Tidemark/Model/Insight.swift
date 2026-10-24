import Foundation

/// What a host is for, as classified by the on-device language model.
enum HostCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case aiInference = "ai-inference"
    case api
    case cdn
    case telemetry
    case analytics
    case ads
    case auth
    case update
    case storage
    case messaging
    case media
    case web
    case unknown
}

/// On-device explanation of a host (row in `host_insights`, shared by every Mac).
struct HostInsight: Codable, Hashable, Sendable {
    var host: String
    var category: HostCategory
    /// Company or service operating the host, e.g. `GitHub`, `Tencent`.
    var operatorName: String?
    /// One or two sentences on what the host is used for.
    var summary: String
    /// Optional privacy or security note ("Sends usage analytics").
    var concern: String?
    /// Language of `summary` (`en`, `zh-Hans`).
    var language: String
    /// Model that produced it, e.g. `AFM 3 Core`.
    var model: String?
    var createdAt: Date
}

/// Facts about a host given to the model so its answer is grounded in what Tidemark saw.
struct HostContext: Hashable, Sendable {
    var host: String
    var appName: String?
    var processName: String?
    var port: Int?
    var ips: [String]
    var geo: GeoInfo?
    var policy: String?
    var firstSeen: Date?
    var requestCount: Int64?
}
