#!/usr/bin/env python3
"""Flashing GUI for the ESP-NOW MQTT Remote firmware.

    python3 tools/flasher/app.py

Serves a page on localhost that walks through: enter credentials -> flash a hub
-> read its ESP-NOW address off the boot log -> configure remotes -> flash them
against that address.

Binds 127.0.0.1 by default. The API returns the stored WiFi, MQTT and OTA
passwords so the form can prefill, and runs builds, so it is only open to this
machine unless you say otherwise.

--host=0.0.0.0 makes it reachable from elsewhere, which is what the container
does so Docker can publish it. Set FLASHER_PASSWORD when you do that: without
it, anyone who can reach the port can read those credentials.
"""

import base64
import hmac
import json
import mimetypes
import os
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config_store  # noqa: E402
import pio_runner  # noqa: E402
import serial_mac  # noqa: E402

STATIC = Path(__file__).resolve().parent / "static"

# Optional gate for when the UI is reachable from more than this machine.
# GET /api/state hands back the WiFi, MQTT and OTA passwords so the form can
# prefill, and /api/flash runs builds, so on a shared network that is worth a
# lock. Unset means no authentication, which is right for a loopback-only run.
#
# Basic auth over plain HTTP stops casual access from other machines. It does
# not stop anyone who can watch the traffic -- the credentials are base64, not
# encrypted. Put it behind a reverse proxy with TLS if that matters.
PASSWORD = os.environ.get("FLASHER_PASSWORD", "")
USERNAME = os.environ.get("FLASHER_USERNAME", "flasher")

_jobs = {}
_job_seq = 0
_job_lock = threading.Lock()


def _new_job(argv, label, start=True):
    """Registers a job, refusing to run two at once.

    Concurrent uploads to the same board, or two builds in one project
    directory, fail in ways that are tedious to explain in a log pane.

    start=False registers the job without spawning a subprocess, for the serial
    capture, which drives the job from its own thread.
    """
    global _job_seq
    with _job_lock:
        for job in _jobs.values():
            if not job.done:
                raise RuntimeError(f"{job.label} is still running")
        _job_seq += 1
        job_id = str(_job_seq)
        job = pio_runner.Job(argv, label)
        _jobs[job_id] = job
    if start:
        job.start()
    return job_id, job


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # The build log is the interesting output, not access logs.

    # -- helpers -----------------------------------------------------------

    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        """True when no password is configured, or the request carries it."""
        if not PASSWORD:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                decoded = base64.b64decode(header[6:]).decode("utf-8")
                user, _, password = decoded.partition(":")
            except (ValueError, UnicodeDecodeError):
                return False
            # compare_digest on both halves, so neither answer leaks by timing.
            return (hmac.compare_digest(user, USERNAME)
                    and hmac.compare_digest(password, PASSWORD))
        return False

    def _challenge(self):
        body = b"Authentication required.\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="ESP-NOW MQTT Remote Flasher"')
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        return json.loads(self.rfile.read(length))

    def _send_static(self, path):
        target = (STATIC / path.lstrip("/")).resolve()
        if not str(target).startswith(str(STATIC)) or not target.is_file():
            self.send_error(404)
            return
        body = target.read_bytes()
        ctype, _ = mimetypes.guess_type(str(target))
        self.send_response(200)
        self.send_header("Content-Type", ctype or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # -- routes ------------------------------------------------------------

    def do_GET(self):
        if not self._authorized():
            return self._challenge()
        route = urlparse(self.path).path
        if route == "/":
            return self._send_static("index.html")
        if route.startswith("/static/"):
            return self._send_static(route[len("/static/"):])
        if route == "/api/state":
            return self._send_json(
                {
                    "state": config_store.load_state(),
                    "secrets": config_store.load_secrets(),
                    "ports": pio_runner.list_ports(),
                    "generated": {
                        "device_config": config_store.DEVICE_CONFIG.exists(),
                        "local_ini": config_store.LOCAL_INI.exists(),
                        "secrets": config_store.SECRETS.exists(),
                    },
                }
            )
        if route == "/api/ports":
            return self._send_json({"ports": pio_runner.list_ports()})
        if route.startswith("/api/stream/"):
            return self._stream(route.rsplit("/", 1)[-1])
        self.send_error(404)

    def do_POST(self):
        if not self._authorized():
            return self._challenge()
        route = urlparse(self.path).path
        try:
            body = self._read_json()
            if route == "/api/secrets":
                config_store.write_secrets(body)
                return self._send_json({"ok": True})
            if route == "/api/config":
                config_store.apply(body)
                return self._send_json({"ok": True})
            if route == "/api/validate":
                config_store.validate_state(body)
                return self._send_json({"ok": True})
            if route == "/api/flash":
                return self._flash(body)
            if route == "/api/capture":
                return self._capture(body)
            if route == "/api/cancel":
                for job in _jobs.values():
                    if not job.done:
                        job.cancel()
                return self._send_json({"ok": True})
        except config_store.ConfigError as exc:
            return self._send_json({"error": str(exc)}, status=400)
        except PermissionError as exc:
            # Almost always a container running as a uid that does not own the
            # mounted project. The raw errno tells you nothing about that.
            return self._send_json(
                {
                    "error": f"Cannot write {exc.filename or 'the config'}: "
                    f"permission denied. The flasher is running as uid "
                    f"{os.getuid()}, which cannot write to your project "
                    f"directory. In Docker, set FLASHER_UID and FLASHER_GID to "
                    f"your own (`id -u` and `id -g`) and restart."
                },
                status=500,
            )
        except RuntimeError as exc:
            # One job at a time; not a server fault, so say so plainly.
            return self._send_json({"error": str(exc)}, status=409)
        except pio_runner.NoPlatformIO as exc:
            return self._send_json({"error": str(exc)}, status=500)
        except serial_mac.CaptureError as exc:
            return self._send_json({"error": str(exc)}, status=400)
        except Exception as exc:  # surfaced in the UI rather than the console
            return self._send_json({"error": f"{type(exc).__name__}: {exc}"}, status=500)
        self.send_error(404)

    # -- actions -----------------------------------------------------------

    def _flash(self, body):
        environment = body.get("environment")
        if not environment:
            return self._send_json({"error": "no environment given"}, status=400)
        # Flashing a remote whose hub address is still unknown would build
        # against the placeholder MAC and fail silently on the bench.
        if environment.startswith("remote_"):
            location = environment[len("remote_"):]
            hub = config_store.missing_hub_mac(config_store.load_state(), location)
            if hub:
                return self._send_json(
                    {
                        "error": f"{location} talks to the {hub} hub, whose address "
                        f"is not captured yet. Flash that hub and capture its "
                        f"address first, or this remote transmits into nothing."
                    },
                    status=400,
                )

        upload = bool(body.get("upload", True))
        argv = pio_runner.build_argv(
            environment, upload=upload, upload_port=body.get("port") or None
        )
        job_id, _ = _new_job(argv, f"{environment} {'upload' if upload else 'build'}")
        return self._send_json({"job": job_id})

    def _capture(self, body):
        port = body.get("port")
        if not port:
            return self._send_json({"error": "no serial port given"}, status=400)
        job_id, job = _new_job(
            [f"(listening on {port})"], f"capture on {port}", start=False
        )

        def run():
            try:
                mac = serial_mac.capture(
                    port,
                    timeout=float(body.get("timeout", 25)),
                    reset=bool(body.get("reset", True)),
                    on_line=job.emit,
                )
                # The UI watches for this marker to fill the MAC field in.
                job.emit(f"##MAC##{mac}")
                job.emit(f"[flasher] captured {mac}")
                job.finish(0)
            except serial_mac.CaptureError as exc:
                job.emit(f"[flasher] {exc}")
                job.finish(1)

        threading.Thread(target=run, daemon=True).start()
        return self._send_json({"job": job_id})

    def _stream(self, job_id):
        job = _jobs.get(job_id)
        if not job:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        q = job.subscribe()
        try:
            while True:
                line = q.get()
                if line is None:
                    payload = json.dumps({"done": True, "returncode": job.returncode})
                    self.wfile.write(f"data: {payload}\n\n".encode())
                    self.wfile.flush()
                    return
                payload = json.dumps({"line": line})
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def _drop_privileges():
    """When running as root over a bind mount, become the project's owner.

    A container starts as root unless told otherwise, and the project arrives
    as a bind mount owned by whoever owns it on the host. Writing
    include/secrets.h as root would either leave root-owned files strewn
    through someone's working copy, or -- far more often -- fail outright,
    because the pinned uid in the compose file was never the right one.

    Adopting the mount's owner makes that correct without anyone having to
    discover their uid. Done here rather than in a shell entrypoint so it needs
    no extra binaries in the image, and so a plain `sudo python3 app.py` behaves
    the same way.
    """
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        return  # Not root: nothing to drop, and nothing we could do anyway.
    try:
        st = os.stat(config_store.ROOT)
    except OSError:
        return
    if st.st_uid == 0:
        return  # Genuinely root-owned; staying root is correct.
    try:
        os.setgroups([])
        os.setgid(st.st_gid)
        os.setuid(st.st_uid)
        print(f"Running as uid {st.st_uid}:{st.st_gid}, the owner of "
              f"{config_store.ROOT}, so generated files stay yours.")
    except OSError as exc:
        print(f"warning: wanted to run as uid {st.st_uid} but could not ({exc}). "
              "Saving may fail with a permission error.")


def _lan_address():
    """This machine's address on the network it routes through, or None.

    Opening a UDP socket sends nothing; it just asks the routing table which
    local address would be used to reach that destination. Inside a container
    this returns the container's own address, which is not what you type into a
    browser -- Docker publishes the port on the host instead.
    """
    import socket

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(0.2)
            s.connect(("192.0.2.1", 9))  # TEST-NET-1, guaranteed unrouted
            return s.getsockname()[0]
    except OSError:
        return None


def main():
    _drop_privileges()

    port = 8765
    host = "127.0.0.1"
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
        elif arg.startswith("--host="):
            host = arg.split("=", 1)[1]

    try:
        pio_runner.find_pio()
    except pio_runner.NoPlatformIO as exc:
        print(f"warning: {exc}\n")

    loopback = host in ("127.0.0.1", "localhost", "::1")
    server = ThreadingHTTPServer((host, port), Handler)
    url = f"http://{'127.0.0.1' if loopback else host}:{port}/"
    print(f"ESP-NOW MQTT Remote flasher on {url}")
    if host == "0.0.0.0":
        # "http://0.0.0.0:8765" is not something you can type into a browser on
        # another machine, so show an address that actually resolves there.
        lan = _lan_address()
        if lan:
            print(f"Reachable on this network at http://{lan}:{port}/")
    if PASSWORD:
        print(f"Password required, username '{USERNAME}'.")
    elif not loopback:
        # Reachable from other machines with nothing in the way of the stored
        # credentials. Worth saying out loud rather than burying in a doc.
        print(f"WARNING: listening on {host} with no password. Anyone who can")
        print("         reach this port can read your WiFi, MQTT and OTA")
        print("         passwords and start builds. Set FLASHER_PASSWORD.")
    # Flushed explicitly: with output redirected to a file, as on a server,
    # Python block-buffers stdout and the warning above would sit unseen.
    print("Ctrl-C to stop.", flush=True)
    if "--no-browser" not in sys.argv[1:] and loopback:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
