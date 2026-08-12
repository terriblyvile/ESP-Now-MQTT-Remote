# ESP-NOW MQTT Remote

Physical remote controls that drive Home Assistant over ESP-NOW and MQTT.

```
[livingroom] --\
[office]     ----ESP-NOW--> [hub] --MQTT--> [broker] --> [Home Assistant]
[bedroom]    --/
```

Any number of remotes, and up to two base stations — one on WiFi, one on
Ethernet — running at the same time.

---

## Setup

Start here. The flasher app does the whole sequence, including reading each
hub's address off its boot log so you never transcribe a MAC by hand.

```bash
python3 tools/flasher/app.py
```

That opens `http://127.0.0.1:8765` in your browser. Its only prerequisite is
PlatformIO on your `PATH` — pyserial, which it needs for the serial capture,
ships with PlatformIO.

The home page has one tile per task, each showing where you have got to —
which credentials are set, which hub addresses are captured, how many remotes
are ready to flash. Work through them in this order the first time.

### Credentials

WiFi network and password, MQTT broker host, port, username and password, and
an OTA password of your choosing. **Save credentials.** Only the hubs use
these; a remote never joins WiFi.

### Radio & topics

Set **WiFi channel** to the channel your access point actually runs on, and
lock the AP to it. This is the single most common reason a remote does nothing
— ESP-NOW has no channel of its own. See [Radio channel](#radio-channel).

### Define Remotes

One row per physical remote. The **location** becomes part of the MQTT topic,
so it is lowercase, underscores only, 15 characters at most. The **display
name** is what Home Assistant shows. **Talks to** picks which hub it unicasts
to. Then **Save configuration**.

### Flash a base station

For each hub you own:

- Plug it in and pick its **serial port**.
- **Flash over USB.** For the WT32-ETH01, follow the five wiring steps on its
  card first — that board has no USB and needs `GPIO 0` tied to `GND`.
- **Capture address.** It listens for the hub's boot banner and fills in the
  ESP-NOW address itself. If it times out, press the board's reset button while
  it is listening.

You only need the hub you actually have. A remote can only be pointed at a hub
whose address is known: you can define remotes first, but the app refuses to
flash one whose hub has no address rather than building firmware that
transmits into nothing.

### Flash a remote

Pick the remote and its port, and flash. Reflash a remote whenever its hub's
address changes.

Nothing needs adding to `configuration.yaml` — once a hub connects, Home
Assistant discovers every device and entity. To give the buttons behaviour, see
[Reacting to a press](#reacting-to-a-press).

### What it writes

Three files, all gitignored. It never edits a tracked file, which is what keeps
your MAC addresses and room names out of commits:

| File | Holds |
|---|---|
| `include/secrets.h` | WiFi, MQTT and OTA credentials |
| `include/device_config.h` | hub MACs, rooms, channel, hold threshold |
| `platformio_local.ini` | one build environment per remote |

`include/config.h` picks up the second through `__has_include`, and
`platformio.ini` pulls in the third through `extra_configs = *_local.ini`. Both
are optional — a clone without them builds the generic defaults, so the manual
route below still works and `tools/check_discovery.sh` still runs.

---

## Setup by hand

**1. Credentials.**

```bash
cp include/secrets.example.h include/secrets.h
```

Fill in WiFi SSID/password, MQTT broker details, and an OTA password.

**2. Tell the remotes which hub to talk to.** Flash a hub, read the MAC it
prints at boot, and put it in `HUB_MAC_WIRED` or `HUB_MAC_WIRELESS` in
[`include/config.h`](include/config.h):

```
[boot] ESP-NOW address AA:BB:CC:DD:EE:01 -- this is what HUB_MAC_ADDRESS ...
```

Use that line. A WT32-ETH01 also has an *Ethernet* MAC, which is a different
address and will not work — ESP-NOW runs on the WiFi interface.

**3. List your remotes** in `REMOTE_LOCATION_TABLE` in `include/config.h`, with
a matching environment in [`platformio.ini`](platformio.ini). Delete rows for
remotes you do not own; each one becomes a Home Assistant device.

**4. Match the radio channel.** Set `WIFI_CHANNEL` to the channel your access
point runs on, and lock the AP to it. See [Radio channel](#radio-channel) —
this is the single most common cause of a remote that does nothing.

**5. Flash.**

```bash
pio run -e hub_eth -t upload          # or -e hub for the wireless one
```

```bash
pio run -e remote_office -t upload
```

Nothing needs adding to `configuration.yaml` — the hub announces every device
and entity over MQTT discovery.

**6. Make the presses do something.** Discovery gets the buttons *into* Home
Assistant; it does not give them behaviour. Import
[`Livingroom Remote Example HA Automation.yaml`](Livingroom%20Remote%20Example%20HA%20Automation.yaml)
(*Settings → Automations → Create → ⋮ → Edit in YAML*, then paste), change
`livingroom` to your room, and fill in the empty `sequence:` blocks. See
[Reacting to a press](#reacting-to-a-press).

## Flashing over the air

```bash
pio run -e hub_eth_ota -t upload
```

`tools/ota_auth.py` passes `OTA_PASSWORD` from `include/secrets.h`. Without it
the upload fails with a misleading `Host ... Not Found`.

## Check it without hardware

```bash
tools/check_discovery.sh
```

Compiles the shared headers on the host and validates both hub variants: JSON
validity, required Home Assistant keys, buffer overflow, per-room routing, hold
commands, retirements, packet size, duplicate GPIOs/names/ids, and that every
room has a build environment and vice versa.

---

## Build targets

| Target | Board | Role |
|---|---|---|
| `remote_*` | `lolin32_lite` | Battery handset. 21 buttons, light-sleeps between presses. One environment per remote. |
| `hub` | `esp32dev` | Base station over WiFi. |
| `hub_eth` | `wt32-eth01` | Base station over Ethernet. |

```
include/config.h            buttons, rooms, hubs, channel, topics -- shared
include/protocol.h          the ESP-NOW packet layout -- shared
include/ha_discovery.h      Home Assistant discovery payloads (no Arduino deps)
include/secrets.h           credentials -- gitignored
src/remote/main.cpp         handset firmware
src/hub/main.cpp            base station, transport-agnostic
src/hub/network.{h,cpp}     WiFi or Ethernet, chosen at build time
tools/check_discovery.sh    validates the whole contract on the host
tools/flasher/              the flashing GUI -- python3 tools/flasher/app.py
```

`include/config.h` is the single source of truth. A button added there gets a
GPIO on the remote and a Home Assistant trigger on the hub with no other edits.

## Running two hubs

ESP-NOW unicast is addressed to one MAC, so **a press reaches exactly one hub** —
they never both report it. Choose per remote:

```ini
[env:remote_bedroom]
extends = remote_base
build_flags = ${env.build_flags} -DREMOTE_LOCATION='"bedroom"'
    -DHUB_MAC_ADDRESS=HUB_MAC_WIRELESS
```

The default is the wired hub. Each hub has its own `HUB_ID`, giving it its own
MQTT client id, topic branch (`home/hub/<id>/*`), OTA hostname and Home
Assistant device. Without that they would share a client id and the broker
would disconnect whichever connected first, repeatedly.

Remote entities carry no availability and no `via_device`. Both would have to
name one particular hub, which is wrong when either may serve a remote.

## Tap versus hold

Buttons in `REMOTE_HOLD_TABLE` send a second command when held:

| Action | Sent | When |
|---|---|---|
| Tap | `select_button` | on release |
| Hold past 500ms | `select_button_held` | the moment the threshold passes |

Exactly one of the two per press; holding longer does not repeat. A button with
a hold command necessarily fires **on release**, because until the threshold
passes there is no telling a tap from a hold. The other twenty fire the instant
they go down, which is why the table is opt-in.

In Home Assistant a hold arrives as a *long press of its own button*, so
`select_button` appears once with both short-press and long-press triggers.

## Home Assistant

One device per remote, plus one per hub.

- **Living Room Remote**, … — 22 device triggers (*Device* → *Office Remote* →
  *"power" button short press*) and a **Last Command** sensor.
- **ESP32 Base Station (eth)** — **Ethernet Link** or **WiFi Signal**,
  **ESP-NOW Channel**, **Uptime**.

### Reacting to a press

Two ways, both fed by the same MQTT message:

| | Device trigger | One MQTT automation |
|---|---|---|
| Built in | the UI, a button at a time | YAML, a whole remote at once |
| Automations needed | up to 22 | 1 |
| Chosen from | *Device* → *Living Room Remote* → *"power" button short press* | a `choose` on `trigger.payload` |

Device triggers need no YAML and are the quicker way to bind a single button.
The one-automation form is what
[`Livingroom Remote Example HA Automation.yaml`](Livingroom%20Remote%20Example%20HA%20Automation.yaml)
does, and it scales better across a whole remote — the command name *is* the
payload, so one trigger and a `choose` cover every button:

```yaml
triggers:
  - trigger: mqtt
    topic: home/livingroom/remote/command
actions:
  - variables:
      button: '{{ trigger.payload }}'
  - choose:
      - alias: select_button_held
        conditions:
          - condition: template
            value_template: '{{ button == ''select_button_held'' }}'
        sequence: []
mode: parallel
max: 10
```

A hold arrives as its own payload, so it gets its own branch. `mode: parallel`
matters — presses can arrive faster than a sequence finishes, and the default
`single` drops them with an "already running" warning.

One file per remote: copy it and change the room in the topic, nothing else.

### Topics

| Topic | Retained | Purpose |
|---|---|---|
| `home/<location>/remote/command` | no | One message per press. Triggers listen here. |
| `home/<location>/remote/last_command` | yes | Mirror for the sensor. |
| `home/hub/<id>/status` | yes | `online` / `offline` for that hub. |
| `home/hub/<id>/{rssi\|link,channel,uptime}` | yes | Diagnostics, every 60s. |

Discovery is retained, so an entity a hub stops announcing would linger
forever. Removed entities are named in `kRetiredHubEntities` /
`kRetiredRemoteEntities` in `ha_discovery.h` and published empty, which is how
Home Assistant is told to delete them.

## Radio channel

ESP-NOW has no channel of its own — it uses whatever the radio is tuned to.

A **WiFi hub** associates with an access point, and the association dictates its
channel. `WIFI_CHANNEL` is therefore only an *expectation* there, and a router
that moves channel silently kills every button. It logs a loud warning on
mismatch and exposes the channel as a sensor.

An **Ethernet hub** never associates, so it pins the radio to `WIFI_CHANNEL` and
nothing can move it. If channel drift is a problem, this is the fix.

Remotes always transmit on `WIFI_CHANNEL`, so it must match.

## Checking a hub is alive

With no network a hub prints a heartbeat every 10s on either transport:

```
[net] ethernet: no connection yet, up 45s, ESP-NOW listening on channel 1
```

Steady uptime means no watchdog resets; restarting from zero means it is
crashing. If a running board prints nothing, check your serial tool is not
asserting DTR/RTS — that holds EN low and keeps the chip in reset.

## Flashing a WT32-ETH01

No USB. Needs a 3.3V USB-to-serial adapter (TX↔RX0, RX↔TX0, GND, 3V3) with
**GPIO 0 tied to GND** to enter download mode, then released and power-cycled to
run. GPIO 0 is also the PHY clock input, which is why there is no auto-reset.

The board definition ships 4MB; `platformio.ini` overrides it to 8MB with
`default_8MB.csv` for two 3.3MB OTA slots.

## Notes

- The wire format is versioned. **Flash both ends** across a protocol change; a
  hub rejects unknown versions and counts them under `version=` in its
  diagnostics rather than failing silently.
- ESP-NOW here is unencrypted and unauthenticated. A hub only republishes
  packets whose version, location *and* command it recognises, which keeps
  arbitrary strings off the bus, but it does not stop someone in range spoofing
  a real press. Add ESP-NOW encryption with a PMK/LMK if that matters.
- GPIO 34–39 are input-only with no internal pullups; they need physical
  pullups.
- GPIO 0, 2, 12 and 15 are strapping pins — holding *power* or *volume_up* while
  resetting a remote may not do what you expect.
