#!/usr/bin/env bash
# Validates everything the two firmwares have to agree on, without hardware:
# the Home Assistant discovery payloads, the remote's pin table, the hold
# commands, per-room topic routing, hub identity and the wire format.
#
#   tools/check_discovery.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

MQTT_BUFFER_SIZE=$(grep -oE '#define MQTT_BUFFER_SIZE [0-9]+' src/hub/main.cpp | awk '{print $3}')

# Both hubs can run at once and they announce different diagnostics under
# different ids, so both are validated rather than just the default.
for VARIANT in wifi eth; do
  FLAGS="-DHUB_ID='\"$VARIANT\"'"
  if [ "$VARIANT" = "eth" ]; then FLAGS="$FLAGS -DHUB_USE_ETHERNET=1"; fi

  eval c++ -std=c++11 -Wall -Wextra -Iinclude $FLAGS \
      -o "$OUT/dump" tools/discovery_dump.cpp
  "$OUT/dump" > "$OUT/messages.tsv"

python3 - "$OUT/messages.tsv" "$MQTT_BUFFER_SIZE" "$VARIANT" <<'PY'
import json, os, re, sys
from collections import Counter

path, buffer_size, variant = sys.argv[1], int(sys.argv[2]), sys.argv[3]
failures = []
pins, names, topics, uids = [], [], [], []
holds, remotes, retired, retired_remote = [], [], [], []
triggers, sensors = {}, {}
packet = hub_id = hub_node = None

VALID_TYPES = {
    "button_short_press", "button_short_release",
    "button_long_press", "button_long_release",
    "button_double_press", "button_triple_press",
    "button_quadruple_press", "button_quintuple_press",
}
ESPNOW_MAX_PAYLOAD = 250

for line in open(path):
    parts = line.rstrip("\n").split("\t")
    kind = parts[0]

    if kind == "PACKET":
        packet = dict(size=int(parts[1]), version=int(parts[2]),
                      max_location=int(parts[3]), max_command=int(parts[4]))
        continue
    if kind == "HUB":
        hub_id, hub_node = parts[1], parts[2]
        continue
    if kind == "PIN":
        pins.append(int(parts[1])); names.append(parts[2]); continue
    if kind == "HOLD":
        holds.append((parts[1], parts[2])); continue
    if kind == "REMOTE":
        remotes.append((parts[1], parts[2])); continue
    if kind == "RETIRED":
        retired.append((parts[1], parts[2], parts[3])); continue
    if kind == "RETIRED_REMOTE":
        retired_remote.append((parts[1], parts[2])); continue

    _, topic, needed, payload = parts
    needed = int(needed)
    topics.append(topic)

    if needed >= buffer_size:
        failures.append(f"{topic}: payload needs {needed}B, MQTT buffer is {buffer_size}B")

    try:
        doc = json.loads(payload)
    except json.JSONDecodeError as e:
        failures.append(f"{topic}: invalid JSON ({e})")
        continue

    node_id = topic.split("/")[2]
    if "unique_id" in doc:
        uids.append(doc["unique_id"])

    if kind == "TRIGGER":
        for key in ("automation_type", "type", "subtype", "topic", "payload", "device"):
            if key not in doc:
                failures.append(f"{topic}: trigger missing '{key}'")
        if doc.get("type") not in VALID_TYPES:
            failures.append(f"{topic}: {doc.get('type')!r} is not a Home Assistant trigger type")
        triggers[(node_id, doc.get("payload"))] = (doc.get("type"), doc.get("subtype"), doc.get("topic"))
    else:
        for key in ("name", "unique_id", "state_topic", "device"):
            if key not in doc:
                failures.append(f"{topic}: sensor missing '{key}'")
        sensors[(node_id, doc.get("unique_id"))] = doc

    ident = doc.get("device", {}).get("identifiers")
    if not ident or ident[0] != node_id:
        failures.append(f"{topic}: device identifiers {ident} do not match node id {node_id!r}")

# --- wire format -----------------------------------------------------------
if packet is None:
    failures.append("dump produced no PACKET row")
else:
    if packet["size"] > ESPNOW_MAX_PAYLOAD:
        failures.append(f"RemotePacket is {packet['size']}B, over the {ESPNOW_MAX_PAYLOAD}B ESP-NOW limit")
    longest_cmd = max(names + [h for _, h in holds], key=len)
    if len(longest_cmd) > packet["max_command"]:
        failures.append(f"longest command {longest_cmd!r} exceeds MAX_COMMAND_LEN {packet['max_command']}")
    longest_loc = max((loc for loc, _ in remotes), key=len)
    if len(longest_loc) > packet["max_location"]:
        failures.append(f"longest location {longest_loc!r} exceeds MAX_LOCATION_LEN {packet['max_location']}")

# --- hub identity ----------------------------------------------------------
# Two hubs run at once, so their ids must be distinct from each other and from
# every location -- a location called "eth" would collide with the hub's node id.
if hub_id in [loc for loc, _ in remotes]:
    failures.append(f"hub id {hub_id!r} collides with a remote location")
if hub_node != f"esp_hub_{hub_id}":
    failures.append(f"hub node id {hub_node!r} does not follow esp_hub_<id>")

hub_uids = {uid for (node, uid) in sensors if node == hub_node}
wanted, unwanted = ("link", "rssi") if variant == "eth" else ("rssi", "link")
if f"{hub_node}_{wanted}" not in hub_uids:
    failures.append(f"{variant} hub does not announce {wanted}")
if f"{hub_node}_{unwanted}" in hub_uids:
    failures.append(f"{variant} hub announces {unwanted}, which it never publishes to")

# Hub entities carry availability; remote entities deliberately do not, because
# either hub may serve a remote and naming one would be wrong.
for (node, uid), doc in sensors.items():
    if node == hub_node and "availability_topic" not in doc:
        failures.append(f"{uid}: hub entity missing availability")
    if node != hub_node and "availability_topic" in doc:
        failures.append(f"{uid}: remote entity must not claim one hub's availability")
    if node != hub_node and "via_device" in doc.get("device", {}):
        failures.append(f"{uid}: remote device must not be via a specific hub")

# --- retirements -----------------------------------------------------------
published_ids = {uid[len(hub_node) + 1:] for uid in hub_uids}
published_state_topics = {d.get("state_topic") for (n, _), d in sensors.items()}

for node_id, object_id, state_topic in retired:
    if node_id == hub_node and object_id in published_ids:
        failures.append(f"{variant} hub retires {object_id!r} but also publishes it")
    if state_topic != "-" and state_topic in published_state_topics:
        failures.append(f"{variant} hub clears {state_topic}, which it still publishes to")

remote_object_ids = {uid.split("_", 2)[-1] for (n, uid) in sensors if n != hub_node}
for object_id, leaf in retired_remote:
    if object_id in remote_object_ids:
        failures.append(f"retires remote entity {object_id!r} but also publishes it")

# --- battery must be gone --------------------------------------------------
source = "".join(open(f).read() for f in
                 ("include/config.h", "include/protocol.h", "include/ha_discovery.h",
                  "src/hub/main.cpp", "src/remote/main.cpp"))
for banned in ("BATTERY_ADC_PIN", "BATTERY_SCALE_MILLI", "batteryPercent",
               "batteryMillivolts", "analogReadMilliVolts"):
    if banned in source:
        failures.append(f"battery monitoring leftover: {banned}")

# --- hold commands ---------------------------------------------------------
for tap, hold in holds:
    if tap not in names:
        failures.append(f"hold table references {tap!r}, not a button in REMOTE_BUTTON_TABLE")
    if hold in names:
        failures.append(f"hold command {hold!r} collides with a button name")

# --- per-remote coverage ---------------------------------------------------
# Locations and environments can come from tracked defaults or from what
# tools/flasher generated. Where a generated file exists it is the authority:
# the tracked defaults are then only a fallback for a clone that has never run
# the flasher, and holding those to a user's room list would be nonsense.
config_sources = ["include/config.h"]
if os.path.exists("include/device_config.h"):
    config_sources.append("include/device_config.h")
config = "".join(open(f).read() for f in config_sources)
config_label = " or ".join(config_sources)

env_source = ("platformio_local.ini" if os.path.exists("platformio_local.ini")
              else "platformio.ini")
platformio = open(env_source).read()

for location, name in remotes:
    node_id = f"esp_hub_{location}"
    expected_topic = f"home/{location}/remote/command"

    for command in names + [h for _, h in holds]:
        key = (node_id, command)
        if key not in triggers:
            failures.append(f"{location}: no trigger for {command!r}")
        elif triggers[key][2] != expected_topic:
            failures.append(f"{location}: {command!r} points at {triggers[key][2]}, expected {expected_topic}")

    for tap, hold in holds:
        if (node_id, hold) in triggers:
            htype, hsubtype, _ = triggers[(node_id, hold)]
            if htype != "button_long_press":
                failures.append(f"{location}: {hold!r} announced as {htype!r}, expected button_long_press")
            if hsubtype != tap:
                failures.append(f"{location}: {hold!r} has subtype {hsubtype!r}, expected {tap!r}")

    if f'"{location}"' not in config:
        failures.append(f"{location}: not found in {config_label}")
    if f"REMOTE_LOCATION='\"{location}\"'" not in platformio:
        failures.append(f"{location}: no matching build environment in {env_source}")

for env_location in re.findall(r"REMOTE_LOCATION='\"([^\"]+)\"'", platformio):
    if env_location not in [loc for loc, _ in remotes]:
        failures.append(f"{env_source} builds {env_location!r}, not in REMOTE_LOCATION_TABLE")

# --- uniqueness ------------------------------------------------------------
all_commands = names + [h for _, h in holds]
for label, values in (("GPIO", pins), ("command name", all_commands),
                      ("location", [loc for loc, _ in remotes]),
                      ("discovery topic", topics), ("unique_id", uids)):
    for value, count in Counter(values).items():
        if count > 1:
            failures.append(f"duplicate {label}: {value!r} appears {count} times")

# --- example automation ----------------------------------------------------
# The README points at this as the way to act on a press, so its branches have
# to stay in step with the button table: a button added to config.h with no
# branch here reaches Home Assistant and then silently does nothing.
example = "Livingroom Remote Example HA Automation.yaml"
try:
    automation = open(example).read()
except FileNotFoundError:
    failures.append(f"{example}: missing, but the README links to it")
else:
    branches = re.findall(r"button == ''([^']+)''", automation)
    for command in all_commands:
        if command not in branches:
            failures.append(f"{example}: no branch for {command!r}")
    for branch in branches:
        if branch not in all_commands:
            failures.append(f"{example}: branch for {branch!r}, not a command")

    # The shipped example is pinned to the default "livingroom". Once you have
    # generated your own rooms it becomes a template to copy per remote rather
    # than a live contract, so only hold it to a real topic while the tracked
    # defaults are what is being built.
    if "include/device_config.h" not in config_sources:
        valid_topics = [f"home/{loc}/remote/command" for loc, _ in remotes]
        for topic in re.findall(r"^\s*topic:\s*(\S+)", automation, re.M):
            if topic not in valid_topics:
                failures.append(f"{example}: triggers on {topic}, which no remote publishes to")
    # A wrapper key here silently swallows the topic filter, and the automation
    # then fires on every message the broker carries.
    if re.search(r"trigger:\s*mqtt\s*\n\s*options:", automation):
        failures.append(f"{example}: mqtt trigger nests topic under 'options:'")

if failures:
    print(f"FAILED ({variant} hub)")
    for f in failures:
        print("  -", f)
    sys.exit(1)

biggest = max(int(l.split("\t")[2]) for l in open(path)
              if l.split("\t")[0] in ("TRIGGER", "SENSOR"))

print(f"OK  {hub_node}: {len(topics)} discovery messages, {len(remotes)} remote(s)")
print(f"    {len(pins)} buttons, {len(holds)} with a hold command, {len(triggers)} triggers")
print(f"    remotes routed to home/<location>/remote/*, hub health on home/hub/{hub_id}/*")
print(f"    {len(retired) + len(retired_remote) * len(remotes)} retirements published, none overlapping live entities")
print(f"    example automation branches on all {len(all_commands)} commands")
print(f"    RemotePacket {packet['size']}B of {ESPNOW_MAX_PAYLOAD}B, protocol v{packet['version']}")
print(f"    largest payload {biggest}B of {buffer_size}B MQTT buffer")
PY

done
