"""Runs PlatformIO as a subprocess and streams its output line by line.

One job at a time. Flashing two boards at once over the same USB bus is not
something the UI should make easy, and a build lock in the same project
directory would fail confusingly anyway.
"""

import glob
import os
import queue
import shutil
import subprocess
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent


class NoPlatformIO(RuntimeError):
    pass


def find_pio():
    found = shutil.which("pio") or shutil.which("platformio")
    if found:
        return found
    # Installed but not on PATH is the common case when PlatformIO came from
    # the VS Code extension rather than pip.
    fallback = Path.home() / ".platformio" / "penv" / "bin" / "pio"
    if fallback.exists():
        return str(fallback)
    raise NoPlatformIO(
        "PlatformIO not found. Install it with `pip install platformio`, or "
        "open this project once in VS Code with the PlatformIO extension."
    )


class Job:
    """A running pio invocation whose output can be tailed by the browser."""

    def __init__(self, argv, label):
        self.argv = argv
        self.label = label
        self.lines = []
        self.done = False
        self.returncode = None
        self._subscribers = []
        self._lock = threading.Lock()
        self._proc = None

    # -- output plumbing ---------------------------------------------------

    def subscribe(self):
        q = queue.Queue()
        with self._lock:
            for line in self.lines:
                q.put(line)
            if self.done:
                q.put(None)
            else:
                self._subscribers.append(q)
        return q

    def emit(self, line):
        """Append a line and fan it out to anyone tailing this job."""
        with self._lock:
            self.lines.append(line)
            for q in self._subscribers:
                q.put(line)

    _emit = emit  # internal alias, kept so _run reads the same as before

    def finish(self, returncode):
        with self._lock:
            self.returncode = returncode
            self.done = True
            for q in self._subscribers:
                q.put(None)
            self._subscribers = []

    # -- lifecycle ---------------------------------------------------------

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        self._emit(f"$ {' '.join(self.argv)}")
        env = dict(os.environ)
        # Without this PlatformIO emits ANSI colour codes that show up as
        # escape sequences in the browser.
        env["PLATFORMIO_NO_ANSI"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        try:
            self._proc = subprocess.Popen(
                self.argv,
                cwd=str(ROOT),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
            )
        except OSError as exc:
            self.emit(f"failed to start: {exc}")
            self.finish(-1)
            return

        for line in self._proc.stdout:
            self.emit(line.rstrip("\n"))
        self._proc.wait()
        self.finish(self._proc.returncode)

    def cancel(self):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()


def build_argv(environment, upload=False, upload_port=None):
    argv = [find_pio(), "run", "-e", environment]
    if upload:
        argv += ["-t", "upload"]
        if upload_port:
            argv += ["--upload-port", upload_port]
    return argv


def list_ports():
    """Serial ports on *this* machine, most-likely-a-board first.

    These are the server's ports, not the browser's. Running the flasher on one
    machine and opening it from another does not make the second machine's USB
    devices appear.
    """
    ports = []
    seen = set()

    def add(device, description, hwid, likely_board):
        real = os.path.realpath(device)
        if real in seen:
            return
        seen.add(real)
        ports.append({"device": device, "description": description,
                      "hwid": hwid, "likely_board": likely_board})

    try:
        from serial.tools import list_ports as _lp
        for p in _lp.comports():
            # Bluetooth and debug-console ttys are never boards.
            if "Bluetooth" in p.device or p.device.endswith("debug-console"):
                continue
            add(p.device, p.description or "", p.hwid or "", bool(p.vid))
    except ImportError:  # pragma: no cover - depends on the host
        pass

    # pyserial identifies ports by walking /sys, which a container usually does
    # not have even when the device node itself was passed in with --device. In
    # that case comports() returns nothing while /dev/ttyUSB0 is sitting right
    # there and perfectly usable, so fall back to the nodes themselves.
    for pattern in ("/dev/serial/by-id/*", "/dev/ttyUSB*", "/dev/ttyACM*",
                    "/dev/cu.usb*", "/dev/cu.wchusb*", "/dev/cu.SLAB*"):
        for device in sorted(glob.glob(pattern)):
            add(device, "detected by device node", "", True)

    ports.sort(key=lambda p: (not p["likely_board"], p["device"]))
    return ports
