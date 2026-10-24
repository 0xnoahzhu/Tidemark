import CryptoKit
import Foundation
import IOKit
import SystemConfiguration

/// Facts about this Mac for its row in `devices`, plus the stable IDs and hues Tidemark derives.
enum CaptureDeviceInfo {
    /// Hues for device dots and badges (the design uses 240, 150 and 65 for its three Macs).
    static let devicePalette: [Double] = [240, 150, 65, 295, 195, 330, 25]
    /// Hues for fallback app tiles.
    static let tilePalette: [Double] = [25, 65, 150, 195, 240, 295, 330]

    /// The computer name from System Settings › General › Sharing.
    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    /// `Mac mini (2024)` from the device tree.
    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let data = value as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `M4` from `Apple M4`.
    static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let brand = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let chip = brand.hasPrefix("Apple ") ? String(brand.dropFirst(6)) : brand
        return chip.isEmpty ? nil : chip
    }

    /// `Mac mini · M4` (best effort).
    static func modelDescription(product: String? = productName(), chip: String? = chipName()) -> String? {
        let family = product.map { name -> String in
            if let paren = name.range(of: " (") { return String(name[..<paren.lowerBound]) }
            return name
        }
        let parts = [family, chip].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Badge label: from the computer name when it names the model (`Noah’s MacBook Pro` → `MBP`),
    /// otherwise from the product name.
    static func shortName(name: String, product: String?) -> String {
        let keywords = ["macbook pro", "macbook air", "mac mini", "mac studio", "imac", "mac pro"]
        let lower = name.lowercased()
        if keywords.contains(where: lower.contains) || product == nil { return Device.shortName(for: name) }
        return Device.shortName(for: product ?? name)
    }

    /// A stable hue for a device ID.
    static func hue(for id: UUID) -> Double {
        devicePalette[Int(stableHash(id.uuidString) % UInt64(devicePalette.count))]
    }

    /// A stable tile hue for an app, from its bundle ID (or path).
    static func tileHue(for key: String) -> Double {
        tilePalette[Int(stableHash(key) % UInt64(tilePalette.count))]
    }

    /// Stable ID of the device row used for requests from a remote Surge, derived from this Mac and the
    /// remote address so it survives relaunches.
    static func remoteDeviceID(thisDevice: DeviceID, remote: String) -> DeviceID {
        let digest = SHA256.hash(data: Data("tidemark-remote|\(thisDevice.uuidString)|\(remote.lowercased())".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The device rows are written under: the remote Surge's row when one is configured.
    @MainActor
    static func recordingDeviceID(_ preferences: Preferences) -> DeviceID {
        let remote = preferences.surgeRemote.trimmingCharacters(in: .whitespaces)
        return remote.isEmpty ? preferences.thisDeviceID : remoteDeviceID(thisDevice: preferences.thisDeviceID, remote: remote)
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }
}
