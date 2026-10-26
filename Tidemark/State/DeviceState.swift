import Foundation
import Observation

/// Macs writing to the shared database and the sidebar's Mac filter.
@MainActor
@Observable
final class DeviceState {
    let thisDeviceID: DeviceID
    /// The Macs as last read from the database.
    var devices: [Device] = []
    /// What this Mac wrote since `devices` was read. The capture engine counts every write flush (about once a
    /// second) here rather than in `devices`, which almost every page reads (device badges, the Mac menu, Installed
    /// on): only the views that show this Mac's counters, through `current(_:)`, update with each flush.
    var thisDeviceWrites = Writes()
    /// Sidebar Mac menu selection.
    var scope: DeviceScope = .all

    /// New rows and the latest write of this Mac.
    struct Writes: Equatable, Sendable {
        var rows: Int64 = 0
        var lastWriteAt: Date?
    }

    init(thisDeviceID: DeviceID) {
        self.thisDeviceID = thisDeviceID
    }

    var thisDevice: Device? { devices.first { $0.id == thisDeviceID } }

    /// `device` with this Mac's writes since the last refresh counted in (row count, last write).
    func current(_ device: Device) -> Device {
        guard device.id == thisDeviceID else { return device }
        var device = device
        device.rowCount += thisDeviceWrites.rows
        if let written = thisDeviceWrites.lastWriteAt, device.lastWriteAt.map({ $0 < written }) ?? true {
            device.lastWriteAt = written
        }
        return device
    }

    func device(_ id: DeviceID) -> Device? { devices.first { $0.id == id } }

    /// Short badge label (`MBP`) for a row's device.
    func shortName(_ id: DeviceID) -> String { device(id)?.shortName ?? "?" }

    func hue(_ id: DeviceID) -> Double { device(id)?.hue ?? 240 }

    /// The device used for per-Mac context (installed checks) when the scope is "All Macs".
    var contextDeviceID: DeviceID { scope.deviceID ?? thisDeviceID }

    /// Whether table rows should show the device badge column.
    var showsDeviceBadges: Bool {
        if case .all = scope { return devices.count > 1 }
        return false
    }
}
