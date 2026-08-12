"""Feeds the OTA password from include/secrets.h into the espota uploader.

The hub firmware calls ArduinoOTA.setPassword(OTA_PASSWORD), so the device
rejects any upload that does not authenticate. PlatformIO has no idea what that
password is: its espota command line is just `--debug --progress -i <host>`.
Without this script an OTA upload fails with a misleading "Host ... Not Found".

Reading the password out of include/secrets.h keeps that file the single source
of truth -- the password never has to be duplicated into platformio.ini (which
is committed) or into a shell variable that could silently drift out of sync.

Registered as a `post:` script so it runs after the espressif32 builder has done
env.Replace(UPLOADERFLAGS=...), which would otherwise wipe the flag out.
"""

import re
import sys
from pathlib import Path

Import("env")  # noqa: F821  (injected by SCons)

PATTERN = re.compile(r'^\s*#define\s+OTA_PASSWORD\s+"([^"]*)"', re.MULTILINE)


def fail(message):
    sys.stderr.write("ota_auth: %s\n" % message)
    env.Exit(1)  # noqa: F821


secrets = Path(env.subst("$PROJECT_INCLUDE_DIR")) / "secrets.h"  # noqa: F821

if not secrets.is_file():
    fail(
        "%s not found. Copy include/secrets.example.h to include/secrets.h "
        "and set OTA_PASSWORD." % secrets
    )

match = PATTERN.search(secrets.read_text())
if match is None:
    fail("no OTA_PASSWORD definition found in %s" % secrets)
elif not match.group(1):
    fail("OTA_PASSWORD in %s is empty" % secrets)
else:
    # espota logs its full option set -- password included -- under --debug, so
    # drop that flag. Progress, "Authenticating...OK" and errors still print.
    flags = [f for f in env["UPLOADERFLAGS"] if f != "--debug"]  # noqa: F821
    env.Replace(UPLOADERFLAGS=flags + ["--auth=" + match.group(1)])  # noqa: F821
