import Foundation

/// Which base station a remote transmits to.
///
/// A remote unicasts to exactly one hub's MAC, which is what lets a wired and a
/// wireless hub run side by side without both reporting the same press.
public enum HubKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case wired
    case wireless

    public var id: String { rawValue }

    /// What the user calls it.
    public var label: String {
        switch self {
        case .wired: "Wired hub"
        case .wireless: "Wireless hub"
        }
    }

    /// The board it runs on, for the one-line explanation in the UI.
    public var boardDescription: String {
        switch self {
        case .wired: "WT32-ETH01 reaching the broker over Ethernet"
        case .wireless: "Plain ESP32 reaching the broker over WiFi"
        }
    }

    /// PlatformIO environment for a USB upload.
    public var environment: String {
        switch self {
        case .wired: "hub_eth"
        case .wireless: "hub"
        }
    }

    /// PlatformIO environment for an over-the-air upload.
    public var otaEnvironment: String {
        switch self {
        case .wired: "hub_eth_ota"
        case .wireless: "hub_ota"
        }
    }

    /// Hostname the hub advertises over mDNS, offered as the OTA default.
    public var otaHostname: String {
        switch self {
        case .wired: "esp_hub_eth.local"
        case .wireless: "esp_hub_wifi.local"
        }
    }

    /// The macro `device_config.h` defines for this hub's address.
    public var macMacro: String {
        switch self {
        case .wired: "HUB_MAC_WIRED"
        case .wireless: "HUB_MAC_WIRELESS"
        }
    }

    /// The WT32-ETH01 has no auto-reset wiring -- GPIO 0 is its PHY clock input
    /// -- so capture there listens for a hand power-cycle instead of pulsing the
    /// reset line.
    public var supportsAutoReset: Bool { self == .wireless }
}

/// One physical handset.
public struct Remote: Codable, Identifiable, Equatable, Sendable {
    /// Local only. Deliberately outside `CodingKeys` so it never reaches
    /// `state.json`, where it would be noise the Python flasher does not expect.
    public var id = UUID()
    public var location: String
    public var name: String
    public var hub: HubKind

    private enum CodingKeys: String, CodingKey {
        case location, name, hub
    }

    public init(location: String, name: String, hub: HubKind) {
        self.location = location
        self.name = name
        self.hub = hub
    }

    /// Compares what gets compiled in, deliberately ignoring `id`.
    ///
    /// The identifier exists so SwiftUI can tell two rows apart while they are
    /// being edited; it is regenerated on every load. Counting it would make a
    /// state reloaded from disk unequal to the one just written, which is what
    /// the unsaved-changes indicator turns on.
    public static func == (lhs: Remote, rhs: Remote) -> Bool {
        lhs.location == rhs.location && lhs.name == rhs.name && lhs.hub == rhs.hub
    }

    /// The PlatformIO environment built for this remote.
    public var environment: String { "remote_\(location.trimmed)" }
}

/// Everything the flasher knows that is not a credential.
///
/// This is `tools/flasher/state.json`, in the same shape the Python flasher
/// writes, so the two can be used interchangeably on one project.
public struct FlasherState: Codable, Equatable, Sendable {
    public var wifiChannel: Int = 1
    public var topicRoot: String = "home"
    public var holdThresholdMs: Int = 500
    public var hubMacWired: String = ""
    public var hubMacWireless: String = ""
    public var remotes: [Remote] = [
        Remote(location: "livingroom", name: "Living Room Remote", hub: .wired)
    ]

    private enum CodingKeys: String, CodingKey {
        case wifiChannel = "wifi_channel"
        case topicRoot = "topic_root"
        case holdThresholdMs = "hold_threshold_ms"
        case hubMacWired = "hub_mac_wired"
        case hubMacWireless = "hub_mac_wireless"
        case remotes
    }

    public init() {}

    /// Decodes key by key, falling back to the default for anything absent.
    ///
    /// Written out rather than synthesised because the synthesised decoder
    /// ignores property defaults and throws on a missing key. A state file from
    /// an older version -- or a hand-edited one -- should still open.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FlasherState()
        wifiChannel = try container.decodeIfPresent(Int.self, forKey: .wifiChannel)
            ?? fallback.wifiChannel
        topicRoot = try container.decodeIfPresent(String.self, forKey: .topicRoot)
            ?? fallback.topicRoot
        holdThresholdMs = try container.decodeIfPresent(Int.self, forKey: .holdThresholdMs)
            ?? fallback.holdThresholdMs
        hubMacWired = try container.decodeIfPresent(String.self, forKey: .hubMacWired) ?? ""
        hubMacWireless = try container.decodeIfPresent(String.self, forKey: .hubMacWireless) ?? ""
        remotes = try container.decodeIfPresent([Remote].self, forKey: .remotes) ?? []
    }

    /// The captured address for one hub, or empty.
    public func mac(for hub: HubKind) -> String {
        switch hub {
        case .wired: hubMacWired
        case .wireless: hubMacWireless
        }
    }

    public mutating func setMac(_ mac: String, for hub: HubKind) {
        switch hub {
        case .wired: hubMacWired = mac
        case .wireless: hubMacWireless = mac
        }
    }

    /// Which hub this remote needs the address of, or nil if it is ready to flash.
    ///
    /// A remote built against the placeholder MAC transmits into nothing, and
    /// ESP-NOW reports no delivery error it could act on. Deliberately not part
    /// of ``ConfigStore/validate(_:)``: you define remotes before flashing a hub,
    /// so demanding an address at save time would block the normal order of work.
    /// It is enforced where it actually matters, at the flash.
    public func missingHubMac(forLocation location: String) -> HubKind? {
        guard let remote = remotes.first(where: { $0.location == location }) else { return nil }
        return mac(for: remote.hub).trimmed.isEmpty ? remote.hub : nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
