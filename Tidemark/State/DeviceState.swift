import Foundation
import Observation

/// Macs writing to the shared database and the sidebar's Mac filter.
@MainActor
@Observable
final class DeviceState {
    let thisDeviceID: DeviceID
    var devices: [Device] = []
    /// Sidebar Mac menu selection.
    var scope: DeviceScope = .all

    init(thisDeviceID: DeviceID) {
        self.thisDeviceID = thisDeviceID
    }

    var thisDevice: Device? { devices.first { $0.id == thisDeviceID } }

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
