# ESP-NOW Remote Flasher — Mac app

A native macOS front end for flashing this project's firmware. Same job as
`tools/flasher`, same generated files, no Python of its own.

See the [main README](../README.md#setup) for how to use it. This file is about
working on it.

## Building

```bash
./build-app.sh          # release build into ./build
./build-app.sh --open   # ...and launch it
```

Requires the Xcode command line tools. The result is
`build/ESP-NOW Remote Flasher.app`, ad-hoc signed and ready to move to
`/Applications`.

During development, `swift build` and `swift test` work as usual. Running the
bare binary from `.build/debug` works too, but a bundled app is what gets a Dock
icon, a menu bar and a stable identity for macOS's permission prompts.

## Layout

| Target | What it is |
|---|---|
| `Sources/FlasherCore` | Everything that touches disk, serial ports or PlatformIO. No UI. |
| `Sources/ESPNowFlasher` | The SwiftUI app: one view per task, plus the log pane. |
| `Tests/FlasherCoreTests` | Unit tests for the core. |

The split is what makes the interesting half testable — every rule about what
makes a valid configuration lives in `FlasherCore` and is covered by tests that
never launch a window.

| File | Responsibility |
|---|---|
| `ConfigStore.swift` | Reads and writes `secrets.h`, `device_config.h`, `platformio_local.ini`, `state.json`. Owns validation. |
| `FlasherState.swift` | The configuration model, in the same JSON shape the Python flasher uses. |
| `SerialPorts.swift` | Enumerates ports through the IO registry, which is also where the human-readable adapter names live. |
| `SerialCapture.swift` | Reads a hub's ESP-NOW address off its boot log over a raw tty. |
| `PIORunner.swift` | Finds `pio`, runs it, streams its output line by line. |
| `ProjectRoot.swift` | Finds and remembers the firmware checkout. |

## Things that are the way they are for a reason

**Not sandboxed.** It runs PlatformIO, opens `/dev/cu.*` and writes into a
checkout you choose. A sandboxed app cannot do any of that without entitlements
this is not signed to carry.

**PlatformIO is searched for by hand.** A process launched from Finder inherits
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and every place PlatformIO installs itself
is outside that. Searching `PATH` alone reports "not found" on a machine where
`pio` works perfectly in Terminal.

**DTR and RTS are cleared before anything else.** On an ESP32 those lines are
wired to EN and GPIO 0. Left asserted they hold the chip in reset and the port
stays silent forever, which reads exactly like a dead board.

**`/dev/cu.*`, never `/dev/tty.*`.** Opening a tty blocks until carrier detect,
which a USB-serial adapter never raises, so the open would simply hang.

**The generated files are byte-identical to the Python flasher's**, apart from
the banner naming whichever tool wrote them. That is deliberate: the two are
meant to be interchangeable on one checkout.
