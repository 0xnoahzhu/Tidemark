import Foundation
import Testing
@testable import Tidemark

/// This Mac's device ID: derived from the hardware UUID, the stored ID only as a fallback or as the legacy ID whose
/// rows are merged.
@MainActor
struct DeviceIdentityTests {
    let scratch = TestDefaults()

    /// A hardware UUID and the device ID the documented Python one-liner derives from it
    /// (`uuid.uuid5(uuid.UUID("52DEF2FE-CE96-4221-91B0-8045B3FD8255"), hardware_uuid.upper())`).
    let hardware = "12345678-9ABC-DEF0-1234-56789ABCDEF0"
    let derived = UUID(uuidString: "830A53DB-09C7-571F-8206-04DB3C44E6E9")!

    @Test func nameBasedUUIDsMatchRFC9562() {
        // RFC 9562's DNS namespace example, as Python's uuid.uuid5 computes it.
        let dns = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        #expect(DeviceIdentity.nameBasedUUID(namespace: dns, name: "python.org") == UUID(uuidString: "886313E1-3B8A-5372-9B90-0C9AEE199E5D"))
        #expect(DeviceIdentity.namespace == UUID(uuidString: "52DEF2FE-CE96-4221-91B0-8045B3FD8255"))
    }

    @Test func derivesTheDocumentedID() {
        #expect(DeviceIdentity.deviceID(hardwareUUID: hardware) == derived)
        // The canonical form: case and surrounding whitespace make no difference.
        #expect(DeviceIdentity.deviceID(hardwareUUID: hardware.lowercased()) == derived)
        #expect(DeviceIdentity.deviceID(hardwareUUID: " \(hardware)\n") == derived)
        #expect(DeviceIdentity.deviceID(hardwareUUID: "00000000-0000-0000-0000-000000000000") == UUID(uuidString: "082E186A-3DA5-514F-B9AC-03BBBD46BA5B"))
        #expect(DeviceIdentity.deviceID(hardwareUUID: "  ") == nil)
        // Never the hardware UUID itself.
        #expect(DeviceIdentity.deviceID(hardwareUUID: hardware)?.uuidString != hardware)
    }

    @Test func derivedIDsAreStableVersion5AndDistinct() {
        var seen = Set<UUID>()
        for _ in 0..<500 {
            let input = UUID().uuidString
            let id = DeviceIdentity.deviceID(hardwareUUID: input)!
            #expect(DeviceIdentity.deviceID(hardwareUUID: input) == id, "stable")
            let bytes = id.uuid
            #expect(bytes.6 >> 4 == 5, "version 5")
            #expect(bytes.8 & 0xC0 == 0x80, "RFC 9562 variant")
            seen.insert(id)
        }
        #expect(seen.count == 500, "different hardware, different IDs")
        // Not a plain UUID string either: an IOPlatformUUID that is not one is used as it is.
        #expect(DeviceIdentity.deviceID(hardwareUUID: "serial-C02XYZ") != DeviceIdentity.deviceID(hardwareUUID: "serial-C02XYW"))
        #expect(DeviceIdentity.deviceID(hardwareUUID: "serial-c02xyz") == DeviceIdentity.deviceID(hardwareUUID: "SERIAL-C02XYZ"))
    }

    @Test func theHardwareIDWinsWithOrWithoutPreferences() {
        // Preferences that cannot be read look empty: the same ID, and nothing is stored.
        let empty = scratch.make()
        let fresh = DeviceIdentity.resolve(defaults: empty, hardwareUUID: hardware)
        #expect(fresh == DeviceIdentity.Resolved(id: derived, legacy: nil))
        #expect(empty.string(forKey: DeviceIdentity.defaultsKey) == nil)

        // An earlier version's random ID is the legacy ID until it is forgotten.
        let upgraded = scratch.make()
        let earlier = UUID()
        upgraded.set(earlier.uuidString, forKey: DeviceIdentity.defaultsKey)
        #expect(DeviceIdentity.resolve(defaults: upgraded, hardwareUUID: hardware) == DeviceIdentity.Resolved(id: derived, legacy: earlier))
        DeviceIdentity.forgetLegacy(UUID(), defaults: upgraded)
        #expect(upgraded.string(forKey: DeviceIdentity.defaultsKey) == earlier.uuidString, "only the legacy ID is forgotten")
        DeviceIdentity.forgetLegacy(earlier, defaults: upgraded)
        #expect(DeviceIdentity.resolve(defaults: upgraded, hardwareUUID: hardware) == DeviceIdentity.Resolved(id: derived, legacy: nil))

        // A stored ID equal to the derived one is no legacy ID.
        let same = scratch.make()
        same.set(derived.uuidString, forKey: DeviceIdentity.defaultsKey)
        #expect(DeviceIdentity.resolve(defaults: same, hardwareUUID: hardware) == DeviceIdentity.Resolved(id: derived, legacy: nil))
    }

    @Test func withoutAHardwareUUIDTheStoredIDIsKept() {
        let defaults = scratch.make()
        let first = DeviceIdentity.resolve(defaults: defaults, hardwareUUID: nil)
        #expect(first.legacy == nil)
        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == first.id.uuidString, "generated once and stored")
        #expect(DeviceIdentity.resolve(defaults: defaults, hardwareUUID: nil) == first)
        #expect(DeviceIdentity.resolve(defaults: defaults, hardwareUUID: "") == first)
        DeviceIdentity.forgetLegacy(UUID(), defaults: defaults)
        #expect(DeviceIdentity.resolve(defaults: defaults, hardwareUUID: nil) == first)
    }

    @Test func preferencesForgetTheLegacyIDOnceMerged() {
        let defaults = scratch.make()
        let earlier = UUID()
        defaults.set(earlier.uuidString, forKey: DeviceIdentity.defaultsKey)
        let preferences = Preferences(defaults: defaults, hardwareUUID: hardware)
        #expect(preferences.thisDeviceID == derived)
        #expect(preferences.legacyDeviceID == earlier)

        preferences.forgetLegacyDeviceID(UUID())
        #expect(preferences.legacyDeviceID == earlier)
        preferences.forgetLegacyDeviceID(earlier)
        #expect(preferences.legacyDeviceID == nil)
        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == nil)
        #expect(Preferences(defaults: defaults, hardwareUUID: hardware).legacyDeviceID == nil, "never merged again")
        #expect(Preferences(defaults: defaults, hardwareUUID: hardware).thisDeviceID == derived)
    }

    /// This Mac's own ID, printed for whoever needs it (`DeviceIdentity` documents a shell command for the same).
    @Test func thisMacHasADerivedID() throws {
        let id = try #require(DeviceIdentity.thisMacDerivedID(), "IOKit reports no IOPlatformUUID")
        #expect(Preferences(defaults: scratch.make()).thisDeviceID == id)
        print("This Mac's device ID: \(id.uuidString)")
    }
}
