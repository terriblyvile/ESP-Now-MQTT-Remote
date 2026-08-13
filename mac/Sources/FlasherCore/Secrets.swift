import Foundation

/// One credential, named as it appears in `include/secrets.h`.
public enum SecretField: String, CaseIterable, Sendable, Identifiable {
    case wifiSSID = "WIFI_SSID"
    case wifiPassword = "WIFI_PASSWORD"
    case mqttHost = "MQTT_HOST"
    case mqttPort = "MQTT_PORT"
    case mqttUsername = "MQTT_USERNAME"
    case mqttPassword = "MQTT_PASSWORD"
    case otaPassword = "OTA_PASSWORD"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .wifiSSID: "WiFi network"
        case .wifiPassword: "WiFi password"
        case .mqttHost: "MQTT broker host"
        case .mqttPort: "MQTT port"
        case .mqttUsername: "MQTT username"
        case .mqttPassword: "MQTT password"
        case .otaPassword: "OTA password"
        }
    }

    /// Shown behind dots, and never copied into a log line.
    public var isPassword: Bool {
        switch self {
        case .wifiPassword, .mqttPassword, .otaPassword: true
        default: false
        }
    }

    public var placeholder: String {
        switch self {
        case .mqttHost: "192.168.1.10"
        case .mqttPort: "1883"
        default: ""
        }
    }

    public var help: String? {
        switch self {
        case .wifiSSID:
            "Only the hubs join WiFi. A remote never does -- it speaks ESP-NOW."
        case .otaPassword:
            "Used when reflashing a running hub over the air."
        default:
            nil
        }
    }
}

/// The contents of `include/secrets.h`.
///
/// Deliberately not `Codable`: these values belong in exactly one file on disk,
/// the gitignored header, and making them trivially serialisable invites a
/// second copy showing up in a cache or a state file.
public struct Secrets: Equatable, Sendable {
    public var wifiSSID = ""
    public var wifiPassword = ""
    public var mqttHost = ""
    public var mqttPort = "1883"
    public var mqttUsername = ""
    public var mqttPassword = ""
    public var otaPassword = ""

    public init() {}

    public subscript(field: SecretField) -> String {
        get {
            switch field {
            case .wifiSSID: wifiSSID
            case .wifiPassword: wifiPassword
            case .mqttHost: mqttHost
            case .mqttPort: mqttPort
            case .mqttUsername: mqttUsername
            case .mqttPassword: mqttPassword
            case .otaPassword: otaPassword
            }
        }
        set {
            switch field {
            case .wifiSSID: wifiSSID = newValue
            case .wifiPassword: wifiPassword = newValue
            case .mqttHost: mqttHost = newValue
            case .mqttPort: mqttPort = newValue
            case .mqttUsername: mqttUsername = newValue
            case .mqttPassword: mqttPassword = newValue
            case .otaPassword: otaPassword = newValue
            }
        }
    }

    /// Enough to build a hub that can reach the broker.
    public var isComplete: Bool {
        !wifiSSID.trimmed.isEmpty && !mqttHost.trimmed.isEmpty
    }
}
