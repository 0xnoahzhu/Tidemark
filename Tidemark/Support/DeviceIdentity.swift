import CryptoKit
import Foundation
import IOKit

/// This Mac's ID in the shared database: its row in `devices` and the `device_id` of every row it writes.
///
/// The ID is derived from the Mac's hardware UUID (`IOPlatformUUID` of `IOPlatformExpertDevice`) as a name-based
/// UUID (RFC 9562 version 5: SHA-1 over `namespace` followed by the name) under Tidemark's own `namespace`. The
/// name is the hardware UUID in canonical form (uppercase, as `ioreg` prints it), encoded as UTF-8. The same Mac
/// always gets the same ID, whether or not its preferences can be read and across reinstalls, and the hardware UUID
/// itself never reaches the shared database. A shell reproduces it:
///
///     python3 -c 'import re, subprocess, uuid
///     hw = re.search(r"\"IOPlatformUUID\" = \"([^\"]+)\"", subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout).group(1)
///     print(str(uuid.uuid5(uuid.UUID("52DEF2FE-CE96-4221-91B0-8045B3FD8255"), hw.upper())).upper())'
///
/// Only when the hardware UUID cannot be read does the ID come from the preferences (`device.id`, generated and
/// stored once), as every ID did before. Those versions kept a random ID there, so a Mac whose preferences could
/// not be read registered as a new Mac. A stored ID that differs from the derived one is this Mac's legacy ID:
/// capture merges its rows into the derived ID (`TidemarkDatabase.mergeDevice`) and then forgets it. IDs stored
/// nowhere are found by the history they share with this Mac (`TidemarkDatabase.devicesSharingHistory`).
enum DeviceIdentity {
    /// Tidemark's namespace for device IDs. Never change it: every Mac's ID is derived from it.
    static let namespace = UUID(uuidString: "52DEF2FE-CE96-4221-91B0-8045B3FD8255")!
    /// The preferences key of the ID earlier versions generated (and of the fallback ID).
    static let defaultsKey = "device.id"

    /// This Mac's ID and, while its rows still have to be merged, the different ID an earlier version stored.
    struct Resolved: Equatable, Sendable {
        var id: DeviceID
        var legacy: DeviceID?
    }

    /// The ID derived from `hardwareUUID` when there is one, with the stored ID as its legacy ID when they differ.
    /// Without a hardware UUID, the stored ID, or a new random one that is stored for the next launch.
    static func resolve(defaults: UserDefaults, hardwareUUID: String?) -> Resolved {
        let stored = defaults.string(forKey: defaultsKey).flatMap(UUID.init(uuidString:))
        if let hardwareUUID, let id = deviceID(hardwareUUID: hardwareUUID) {
            return Resolved(id: id, legacy: stored == id ? nil : stored)
        }
        if let stored { return Resolved(id: stored, legacy: nil) }
        let id = UUID()
        defaults.set(id.uuidString, forKey: defaultsKey)
        return Resolved(id: id, legacy: nil)
    }

    /// Forgets the stored legacy ID once its rows were merged, so the merge never runs again. A stored ID that is
    /// no longer `legacy` (the fallback of a Mac without a readable hardware UUID) stays.
    static func forgetLegacy(_ legacy: DeviceID, defaults: UserDefaults) {
        guard defaults.string(forKey: defaultsKey).flatMap(UUID.init(uuidString:)) == legacy else { return }
        defaults.removeObject(forKey: defaultsKey)
    }

    /// The device ID of the Mac whose hardware UUID this is; nil for an empty one. A hardware UUID that is not a
    /// UUID at all is used as it is, uppercased.
    static func deviceID(hardwareUUID: String) -> DeviceID? {
        let trimmed = hardwareUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = UUID(uuidString: trimmed)?.uuidString ?? trimmed.uppercased()
        return nameBasedUUID(namespace: namespace, name: name)
    }

    /// This Mac's ID from its hardware UUID; nil when it cannot be read.
    static func thisMacDerivedID() -> DeviceID? {
        hardwareUUID().flatMap(deviceID(hardwareUUID:))
    }

    /// RFC 9562 version 5 UUID: the first 16 bytes of SHA-1(namespace bytes + UTF-8 name), with the version (5) and
    /// variant (RFC) bits set. Equals Python's `uuid.uuid5(namespace, name)`.
    static func nameBasedUUID(namespace: UUID, name: String) -> UUID {
        var hash = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hash.update(bufferPointer: $0) }
        hash.update(data: Data(name.utf8))
        var b = Array(hash.finalize().prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The hardware UUID (`IOPlatformUUID`), nil when IOKit does not report one.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
