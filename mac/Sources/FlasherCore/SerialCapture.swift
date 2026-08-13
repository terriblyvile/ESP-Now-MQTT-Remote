import Darwin
import Foundation

public struct CaptureError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Reads a hub's ESP-NOW address off its boot log.
///
/// The hub prints, once per boot:
///
///     [boot] ESP-NOW address AA:BB:CC:DD:EE:01 -- this is what HUB_MAC_ADDRESS ...
///
/// That is the WiFi MAC. On the Ethernet hub it is deliberately not the Ethernet
/// MAC, which is a different address that remotes cannot reach.
///
/// Talks to the tty directly rather than through pyserial, so the app carries no
/// Python of its own. The care taken over DTR and RTS is the same either way: on
/// an ESP32 those lines are wired to EN and GPIO 0, and left asserted they hold
/// the chip in reset. The port then stays silent forever, which reads exactly
/// like a dead board.
public enum SerialCapture {
    /// Set by the boot banner. Anchored on the wording so a MAC printed for some
    /// other reason is not mistaken for the one being asked for.
    static let bootMacPattern = "ESP-NOW address\\s+((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})"
    /// Fallback: any bare MAC on a `[boot]` line, in case the wording changes.
    static let anyMacPattern = "((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})"

    /// Listen on `port` for the boot banner and return the MAC.
    ///
    /// `pulseReset` toggles the board's reset line so the banner is reprinted.
    /// That works on any board with the usual USB-serial auto-reset wiring. The
    /// WT32-ETH01 has none -- GPIO 0 is its PHY clock input -- so it is called
    /// with `false` and the user power-cycles by hand.
    ///
    /// Blocking, and meant to be called off the main thread.
    public static func capture(
        port: String,
        timeout: TimeInterval = 30,
        pulseReset: Bool = true,
        isCancelled: @Sendable () -> Bool = { false },
        onLine: @Sendable (String) -> Void = { _ in }
    ) throws -> String {
        // O_NONBLOCK so the open itself cannot hang on a port that never raises
        // carrier; cleared again below now that the descriptor exists.
        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw CaptureError("could not open \(port): \(errnoMessage())")
        }
        defer { close(fd) }

        // Refuse to share the port. Without this a serial monitor left running
        // elsewhere silently steals half the output, and the banner goes missing
        // for no visible reason.
        guard ioctl(fd, TIOCEXCL) == 0 else {
            throw CaptureError(
                "\(port) is already open in another program. Close any serial "
                + "monitor and try again."
            )
        }
        guard fcntl(fd, F_SETFL, 0) == 0 else {
            throw CaptureError("could not configure \(port): \(errnoMessage())")
        }

        try configure(fd: fd, port: port)
        clear(fd: fd, lines: TIOCM_DTR | TIOCM_RTS)
        tcflush(fd, TCIFLUSH)

        if pulseReset {
            onLine("[flasher] pulsing reset")
            // EN low then high. DTR stays clear throughout so GPIO 0 is never
            // pulled down -- that would boot the chip into the ROM loader
            // instead of the application, and no banner would ever appear.
            set(fd: fd, lines: TIOCM_RTS)
            usleep(120_000)
            clear(fd: fd, lines: TIOCM_RTS)
        } else {
            onLine("[flasher] listening -- press reset or power-cycle the board")
        }

        return try read(fd: fd, port: port, timeout: timeout,
                        isCancelled: isCancelled, onLine: onLine)
    }

    // MARK: - line handling

    private static func read(
        fd: Int32,
        port: String,
        timeout: TimeInterval,
        isCancelled: @Sendable () -> Bool,
        onLine: @Sendable (String) -> Void
    ) throws -> String {
        let bootMac = try! NSRegularExpression(pattern: bootMacPattern)
        let anyMac = try! NSRegularExpression(pattern: anyMacPattern)

        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 512)

        while Date() < deadline {
            if isCancelled() { throw CaptureError("capture cancelled") }

            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                // VTIME expiry and interrupted reads are both ordinary here.
                if errno == EINTR || errno == EAGAIN { continue }
                throw CaptureError("read failed on \(port): \(errnoMessage())")
            }
            if n == 0 { continue }

            pending.append(contentsOf: buffer[0..<n])
            for line in takeLines(&pending) {
                if !line.isEmpty { onLine(line) }
                // Invalid UTF-8 becomes replacement characters rather than
                // failing the decode, so a line of boot-time line noise cannot
                // abort a capture that is otherwise going fine.
                if let mac = firstMatch(bootMac, in: line)
                    ?? (line.hasPrefix("[boot]") ? firstMatch(anyMac, in: line) : nil) {
                    return mac.uppercased()
                }
            }
        }

        throw CaptureError(
            "no boot banner on \(port) within \(Int(timeout))s. If the board is "
            + "running, press its reset button while this is listening; if it is "
            + "a WT32-ETH01, power-cycle it."
        )
    }

    /// Splits off every complete line, leaving any partial one buffered.
    private static func takeLines(_ pending: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            lines.append(
                String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            )
        }
        return lines
    }

    private static func firstMatch(_ regex: NSRegularExpression, in line: String) -> String? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[range])
    }

    // MARK: - tty setup

    private static func configure(fd: Int32, port: String) throws {
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            throw CaptureError("\(port) is not a serial port: \(errnoMessage())")
        }
        cfmakeraw(&settings)
        cfsetispeed(&settings, speed_t(B115200))
        cfsetospeed(&settings, speed_t(B115200))

        // CLOCAL: ignore modem control lines, so a missing carrier does not stop
        // reads. CREAD: actually enable the receiver. No flow control, because
        // asserting RTS for handshaking is exactly what must not happen here.
        settings.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)

        // VMIN 0 with VTIME 2 makes read() return after 200ms of silence rather
        // than blocking forever, which is what lets the timeout be honoured.
        withUnsafeMutableBytes(of: &settings.c_cc) { raw in
            raw[Int(VMIN)] = 0
            raw[Int(VTIME)] = 2
        }

        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            throw CaptureError("could not configure \(port): \(errnoMessage())")
        }
    }

    private static func set(fd: Int32, lines: Int32) {
        var bits = lines
        _ = ioctl(fd, TIOCMBIS, &bits)
    }

    private static func clear(fd: Int32, lines: Int32) {
        var bits = lines
        _ = ioctl(fd, TIOCMBIC, &bits)
    }

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
