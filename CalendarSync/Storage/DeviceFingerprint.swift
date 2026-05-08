import Foundation

/// Device fingerprint sent to EAS in URL query (`DeviceId`, `DeviceType`),
/// the `User-Agent` header, and the `Settings:DeviceInformation` block of
/// Provision Phase 1.
///
/// We pose as a recent iPhone running iOS Mail. EAS servers commonly inspect
/// these fields to enforce per-device policies and to surface the device in
/// admin UIs; matching a real iPhone profile keeps the server happy.
struct DeviceFingerprint: Codable, Equatable {
    /// Hex string, lowercase. EAS treats the value opaquely; iPhone Mail uses
    /// 32-character lowercase hex (an MD5-ish digest of internal identifiers).
    var deviceId: String

    /// EAS DeviceType. iOS Mail reports `iPhone`.
    var deviceType: String

    /// EAS Model identifier (e.g. `iPhone15,2`).
    var model: String

    /// Human-readable OS string (e.g. `iOS 17.4`).
    var os: String

    /// Two-letter language code (e.g. `en`).
    var osLanguage: String

    /// HTTP User-Agent header. iPhone Mail uses `Apple-iPhoneNNCM/BBBB.PPP`.
    var userAgent: String

    /// Friendly name shown in the Exchange admin UI (`iPhone`, `John's iPhone`, ...).
    var friendlyName: String

    /// Builds a brand-new randomised iPhone fingerprint.
    static func randomIPhone() -> DeviceFingerprint {
        let preset = Self.iPhonePresets.randomElement() ?? Self.iPhonePresets[0]
        return DeviceFingerprint(
            deviceId: makeRandomDeviceId(),
            deviceType: "iPhone",
            model: preset.model,
            os: preset.os,
            osLanguage: Locale.current.language.languageCode?.identifier ?? "en",
            userAgent: preset.userAgent,
            friendlyName: "iPhone"
        )
    }

    /// 32-char lowercase hex. Matches the format Apple Mail uses on the wire.
    static func makeRandomDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Presets

    /// Hand-curated set of iPhone profiles seen on the wire from real devices.
    /// The mapping `model -> OS -> UA` is the authentic combination Apple
    /// shipped, so we keep them as one tuple to avoid producing impossible
    /// pairs (e.g. iPhone 16 Pro on iOS 15).
    struct Preset {
        let model: String
        let os: String
        let userAgent: String
    }

    static let iPhonePresets: [Preset] = [
        // iPhone 15 Pro / 15 Pro Max
        Preset(model: "iPhone16,1", os: "iOS 17.4.1", userAgent: "Apple-iPhone16C1/2104.108"),
        Preset(model: "iPhone16,2", os: "iOS 17.4.1", userAgent: "Apple-iPhone16C2/2104.108"),
        Preset(model: "iPhone16,2", os: "iOS 17.5.1", userAgent: "Apple-iPhone16C2/2106.83"),
        // iPhone 15 / 15 Plus
        Preset(model: "iPhone15,4", os: "iOS 17.3.1", userAgent: "Apple-iPhone15C4/2103.50"),
        Preset(model: "iPhone15,5", os: "iOS 17.4.1", userAgent: "Apple-iPhone15C5/2104.108"),
        // iPhone 14 Pro / 14 Pro Max
        Preset(model: "iPhone15,2", os: "iOS 16.7.7", userAgent: "Apple-iPhone15C2/2007.85"),
        Preset(model: "iPhone15,3", os: "iOS 17.5.1", userAgent: "Apple-iPhone15C3/2106.83"),
        // iPhone 14 / 14 Plus
        Preset(model: "iPhone14,7", os: "iOS 17.4.1", userAgent: "Apple-iPhone14C7/2104.108"),
        Preset(model: "iPhone14,8", os: "iOS 17.5.1", userAgent: "Apple-iPhone14C8/2106.83"),
        // iPhone 13 family
        Preset(model: "iPhone14,5", os: "iOS 17.4.1", userAgent: "Apple-iPhone14C5/2104.108"),
        Preset(model: "iPhone14,2", os: "iOS 16.7.7", userAgent: "Apple-iPhone14C2/2007.85"),
        // iPhone 12 / 12 Pro
        Preset(model: "iPhone13,2", os: "iOS 16.7.7", userAgent: "Apple-iPhone13C2/2007.85"),
        Preset(model: "iPhone13,3", os: "iOS 16.7.7", userAgent: "Apple-iPhone13C3/2007.85"),
        // iPhone 11
        Preset(model: "iPhone12,1", os: "iOS 16.7.7", userAgent: "Apple-iPhone12C1/2007.85"),
        // iPhone SE 2/3
        Preset(model: "iPhone12,8", os: "iOS 16.7.7", userAgent: "Apple-iPhone12C8/2007.85"),
        Preset(model: "iPhone14,6", os: "iOS 17.4.1", userAgent: "Apple-iPhone14C6/2104.108")
    ]
}
