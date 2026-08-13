import Foundation
import IOKit
import IOKit.serial

/// A serial device on this Mac.
public struct SerialPort: Identifiable, Hashable, Sendable {
    /// The callout device, `/dev/cu.something`. Always the callout rather than
    /// `/dev/tty.*`: opening a tty blocks until carrier detect, which a plain
    /// USB-serial adapter never raises, so the open would simply hang.
    public let device: String
    public let name: String
    /// Came in over USB, so it is plausibly a board rather than a modem
    /// emulation or a debug tty.
    public let likelyBoard: Bool

    public var id: String { device }

    /// What the picker shows.
    public var label: String {
        name.isEmpty ? device : "\(device) — \(name)"
    }
}

/// Enumerates serial ports through the IO registry.
///
/// This replaces pyserial. The registry is also where the useful names live: the
/// device node alone is `/dev/cu.usbserial-210`, while the USB descriptors a few
/// levels up say which adapter that actually is.
public enum SerialPorts {
    /// Ports on this Mac, most-likely-a-board first.
    public static func list() -> [SerialPort] {
        var found: [String: SerialPort] = [:]

        for port in registryPorts() {
            found[port.device] = port
        }

        // Fall back to the device nodes themselves for anything the registry
        // walk missed. Cheap, and it keeps a working port from disappearing out
        // of the list because its driver populated the registry unusually.
        for device in globbedDevices() where found[device] == nil {
            found[device] = SerialPort(device: device, name: "", likelyBoard: true)
        }

        return found.values
            .filter(isPlausibleBoard)
            .sorted { ($0.likelyBoard ? 0 : 1, $0.device) < ($1.likelyBoard ? 0 : 1, $1.device) }
    }

    /// Neither of these is ever a board, and both are present on every Mac.
    /// Listing them means the first entry in the picker is usually wrong.
    static func isPlausibleBoard(_ port: SerialPort) -> Bool {
        !port.device.contains("Bluetooth")
            && !port.device.hasSuffix("debug-console")
            && !port.device.hasSuffix("wlan-debug")
    }

    private static func registryPorts() -> [SerialPort] {
        let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching as CFDictionary, &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [SerialPort] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let device = property(service, kIOCalloutDeviceKey) as? String else { continue }

            // The descriptors live on the USB device a few levels up the plane,
            // not on the serial node itself.
            let vendor = searchProperty(service, "USB Vendor Name") as? String
            let product = searchProperty(service, "USB Product Name") as? String
            let name = [vendor, product].compactMap { $0 }.joined(separator: " ")

            ports.append(SerialPort(
                device: device,
                name: name.isEmpty ? (property(service, kIOTTYDeviceKey) as? String ?? "") : name,
                likelyBoard: searchProperty(service, "idVendor") != nil
            ))
        }
        return ports
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func searchProperty(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }

    private static func globbedDevices() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/\($0)" }
            .sorted()
    }
}
