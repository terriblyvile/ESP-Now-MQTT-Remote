#!/usr/bin/env python3
"""Flashing GUI for the remote firmware.

    python3 tools/flasher/app.py

Serves a page on localhost that walks through: enter credentials -> flash a hub
-> read its ESP-NOW address off the boot log -> configure remotes -> flash them
against that address.

Bound to 127.0.0.1 on purpose. The API writes credentials to disk and runs
builds, so it must not be reachable from the network.
"""

import json
import mimetypes
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


def main():
    port = 8765
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])

    try:
        pio_runner.find_pio()
    except pio_runner.NoPlatformIO as exc:
        print(f"warning: {exc}\n")

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"Remote Firmware flasher on {url}")
    print("Ctrl-C to stop.")
    if "--no-browser" not in sys.argv[1:]:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
