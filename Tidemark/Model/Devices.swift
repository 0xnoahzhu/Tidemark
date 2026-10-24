import Foundation

/// A Mac (or a remote Surge instance tagged by a Mac) writing to the shared database (row in `devices`).
struct Device: Identifiable, Hashable, Codable, Sendable {
    var id: DeviceID
    var name: String
    /// e.g. `Mac mini · M4`
    var model: String?
    /// Compact label shown in table badges, e.g. `MBP`, `mini`.
    var shortName: String
    /// OKLCH hue used for the device dot and badge.
    var hue: Double
    var isRemoteSurge: Bool
    var rowCount: Int64
    var lastWriteAt: Date?
    var createdAt: Date

    enum Activity: Equatable, Sendable {
        case writingNow
        case lastWrite(seconds: Int)
        case offline(hours: Int)
        case never
    }

    func activity(now: Date = .now) -> Activity {
        guard let lastWriteAt else { return .never }
        let age = now.timeIntervalSince(lastWriteAt)
        if age < 5 { return .writingNow }
        if age < 300 { return .lastWrite(seconds: Int(age)) }
        return .offline(hours: max(1, Int(age / 3600)))
    }

    var isOnline: Bool {
        switch activity() {
        case .writingNow, .lastWrite: true
        default: false
        }
    }

    /// Derives a short badge label from a device name (`MacBook Pro` → `MBP`, `Mac mini (Office)` → `mini`).
    static func shortName(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("macbook pro") { return "MBP" }
        if lower.contains("macbook air") { return "MBA" }
        if lower.contains("mac mini") { return "mini" }
        if lower.contains("mac studio") { return "Std" }
        if lower.contains("imac") { return "iMac" }
        if lower.contains("mac pro") { return "Pro" }
        let letters = name.split(separator: " ").compactMap(\.first).map(String.init).joined()
        return String(letters.prefix(4))
    }
}

/// Which Mac's data the UI shows (sidebar Mac menu).
enum DeviceScope: Hashable, Sendable {
    case all
    case device(DeviceID)

    func includes(_ id: DeviceID) -> Bool {
        switch self {
        case .all: true
        case .device(let d): d == id
        }
    }

    var deviceID: DeviceID? {
        if case .device(let id) = self { return id }
        return nil
    }
}
