"""Reads a hub's ESP-NOW address off its boot log.

The hub prints, once per boot:

    [boot] ESP-NOW address AA:BB:CC:DD:EE:01 -- this is what HUB_MAC_ADDRESS ...

That is the WiFi MAC. On the Ethernet hub it is deliberately not the Ethernet
MAC, which is a different address that remotes cannot reach.

Opening a serial port asserts DTR and RTS by default, and on an ESP32 those
lines are wired to EN and GPIO 0. Left asserted they hold the chip in reset,
and the port then stays silent forever -- which reads exactly like a dead
board. Every open here clears both lines first.
"""

import re
import time

BOOT_MAC_RE = re.compile(
    r"ESP-NOW address\s+((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})"
)
# Fallback: any bare MAC on a [boot] line, in case the wording changes.
ANY_MAC_RE = re.compile(r"((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})")


class CaptureError(RuntimeError):
    pass


def capture(port, timeout=25.0, reset=True, on_line=None):
    """Listen on `port` for the boot banner and return the MAC.

    reset=True pulses the board's reset line so the banner is reprinted. That
    works on any board with the usual USB-serial auto-reset wiring. The
    WT32-ETH01 has none -- GPIO 0 is its PHY clock input -- so it is called with
    reset=False and the user power-cycles by hand.
    """
    try:
        import serial
    except ImportError:  # pragma: no cover - depends on the host
        raise CaptureError(
            "pyserial is not installed. It ships with PlatformIO; try running "
            "this from the same Python that has `pio`."
        )

    def log(message):
        if on_line:
            on_line(message)

    try:
        ser = serial.Serial()
        ser.port = port
        ser.baudrate = 115200
        ser.timeout = 0.3
        # Must be set before open(), or pyserial raises them on the way in.
        ser.dtr = False
        ser.rts = False
        ser.open()
    except Exception as exc:
        raise CaptureError(f"could not open {port}: {exc}")

    try:
        ser.dtr = False
        ser.rts = False
        ser.reset_input_buffer()

        if reset:
            # EN low then high. DTR stays clear throughout so GPIO 0 is never
            # pulled down -- that would boot the chip into the ROM loader
            # instead of the application, and no banner would ever appear.
            log("[flasher] pulsing reset")
            ser.rts = True
            time.sleep(0.12)
            ser.rts = False
        else:
            log("[flasher] listening -- press reset or power-cycle the board")

        deadline = time.time() + timeout
        buffered = ""
        while time.time() < deadline:
            chunk = ser.read(256).decode("utf-8", errors="replace")
            if not chunk:
                continue
            buffered += chunk
            while "\n" in buffered:
                line, buffered = buffered.split("\n", 1)
                line = line.rstrip("\r")
                if line:
                    log(line)
                m = BOOT_MAC_RE.search(line) or (
                    ANY_MAC_RE.search(line) if line.startswith("[boot]") else None
                )
                if m:
                    return m.group(1).upper()
        raise CaptureError(
            f"no boot banner on {port} within {timeout:.0f}s. If the board is "
            "running, press its reset button while this is listening; if it is "
            "a WT32-ETH01, power-cycle it."
        )
    finally:
        ser.close()
