#pragma once

// Shared between the remote and hub build targets. Anything both ends must
// agree on lives here so they cannot drift out of sync.
//
// Values below marked overridable can be supplied by include/device_config.h,
// which tools/flasher generates from what you enter in its UI. That file is
// gitignored, so your own MACs and room names never end up in a commit -- the
// defaults here stay generic. Everything works without it; the flasher is a
// convenience, not a dependency.
#if defined(__has_include)
#if __has_include("device_config.h")
#include "device_config.h"
#endif
#endif

// ---------------------------------------------------------------------------
// RADIO
// ---------------------------------------------------------------------------

// ESP-NOW rides whatever channel the radio is already on.
//
// A WiFi hub associates with an access point, and the association dictates its
// channel -- so there this is only an *expectation*, and a router that moves
// channel silently kills every button. An Ethernet hub never associates and
// pins the radio here instead. Either way the remotes transmit on this.
//
// Overridable by device_config.h.
#ifndef WIFI_CHANNEL
#define WIFI_CHANNEL 1
#endif

// Which base station a remote transmits to. ESP-NOW unicast is addressed to one
// MAC, so a packet reaches exactly one hub -- which is what lets a wired and a
// wireless hub run side by side without both reporting the same press.
//
// Named so a remote can pick one with a plain build flag:
//
//   -DHUB_MAC_ADDRESS=HUB_MAC_WIRELESS
//
// Use a hub's *WiFi* MAC even for the wired one: ESP-NOW runs on the WiFi
// interface, and the board's Ethernet MAC is a different address that will not
// work. Each hub prints the right one at boot.
// Placeholders. Replace both with your own hubs' addresses before flashing a
// remote -- a remote built against these transmits into nothing, and ESP-NOW
// gives no delivery error it can act on, so it fails silently. tools/flasher
// reads each hub's address off its boot log and fills these in for you.
//
// Overridable by device_config.h.
#ifndef HUB_MAC_WIRED
#define HUB_MAC_WIRED                                                          \
  { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01 } // WT32-ETH01
#endif
#ifndef HUB_MAC_WIRELESS
#define HUB_MAC_WIRELESS                                                       \
  { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x02 } // ESP32
#endif

#ifndef HUB_MAC_ADDRESS
#define HUB_MAC_ADDRESS HUB_MAC_WIRED
#endif

// Longest command name is "select_button_held" (18).
#define MAX_COMMAND_LEN 31

// Longest location name, e.g. "livingroom" (10).
#define MAX_LOCATION_LEN 15

// ---------------------------------------------------------------------------
// HUBS
// ---------------------------------------------------------------------------

// Both hubs can run at once. Each needs its own identity, or they collide on
// the MQTT client id -- which makes the broker disconnect whichever connected
// first, over and over -- as well as on the last-will topic and the Home
// Assistant device.
//
// Set per build environment. Must not collide with any location below.
#ifndef HUB_ID
#define HUB_ID "wifi"
#endif

#define HUB_NODE_ID "esp_hub_" HUB_ID

// ---------------------------------------------------------------------------
// REMOTES
// ---------------------------------------------------------------------------

// One entry per physical remote. The location becomes part of the MQTT topic --
// "livingroom" gives home/livingroom/remote/* -- and the name is what Home
// Assistant shows.
//
// Each remote is flashed from its own environment with its location compiled
// in, and the hub reads it out of the packet, so no hub needs per-remote setup.
// This table is also what the hubs validate against: a packet claiming some
// other location is dropped rather than published.
//
// Every entry becomes a Home Assistant device as soon as a hub connects,
// whether or not that remote exists yet. Delete rows you have no hardware for.
//
// Overridable by device_config.h, which is how tools/flasher lets you add,
// rename or remove remotes without touching a tracked file.
#ifndef REMOTE_LOCATION_TABLE
#define REMOTE_LOCATION_TABLE(X)                                               \
  /*  location,       Home Assistant name */                                   \
  X("livingroom", "Living Room Remote")                                        \
  X("office", "Office Remote")                                                 \
  X("bedroom", "Bedroom Remote")
#endif

// Which location this remote build identifies as. Set per build environment.
#ifndef REMOTE_LOCATION
#define REMOTE_LOCATION "livingroom"
#endif

// ---------------------------------------------------------------------------
// IDENTITY / MQTT TOPICS
// ---------------------------------------------------------------------------

#define FIRMWARE_VERSION "2.0.0"

#define HUB_FRIENDLY_NAME "ESP32 Base Station (" HUB_ID ")"

// Overridable by device_config.h.
#ifndef TOPIC_ROOT
#define TOPIC_ROOT "home"
#endif

// Per-remote topics are built at runtime as home/<location>/remote/<leaf>, and
// are deliberately independent of which hub relayed the press -- a remote is
// the same remote whichever base station heard it.
#define TOPIC_REMOTE_SEGMENT "remote"

// Fired once per button press, NOT retained. Home Assistant device triggers
// listen here; retaining it would replay the last press on every HA restart.
#define LEAF_COMMAND "command"

// Retained mirror, so the "Last Command" sensor survives a restart.
#define LEAF_LAST_COMMAND "last_command"

// Each hub's own health, on its own branch so two hubs never overwrite each
// other.
#define HUB_TOPIC_PREFIX TOPIC_ROOT "/hub/" HUB_ID

#define TOPIC_STATUS HUB_TOPIC_PREFIX "/status"
#define PAYLOAD_ONLINE "online"
#define PAYLOAD_OFFLINE "offline"

// Only one of rssi/link exists, depending on the transport. See
// src/hub/network.h.
#define TOPIC_RSSI HUB_TOPIC_PREFIX "/rssi"
#define TOPIC_LINK HUB_TOPIC_PREFIX "/link"
#define TOPIC_CHANNEL HUB_TOPIC_PREFIX "/channel"
#define TOPIC_UPTIME HUB_TOPIC_PREFIX "/uptime"

// Where Home Assistant listens for MQTT discovery. Only change this if you
// changed it in the HA MQTT integration too.
#define HA_DISCOVERY_PREFIX "homeassistant"

// Remote devices are named independently of any hub, so their entities survive
// being served by a different one. Historical value: changing it would strand
// every existing entity.
#define REMOTE_NODE_PREFIX "esp_hub"

// ---------------------------------------------------------------------------
// BUTTON / COMMAND TABLE
// ---------------------------------------------------------------------------

// The single source of truth for what buttons exist. X-macro so both targets
// expand the same list: the remote pairs each entry with its GPIO, the hub uses
// the names for Home Assistant discovery and to whitelist inbound packets.
//
// GPIO notes:
//   34-39 are input-only with no internal pullup -- they need physical pullup
//   resistors or they will float and fire constantly.
//   0, 2, 12 and 15 are strapping pins; holding them at boot affects how the
//   chip starts (0 low = bootloader, 12 high = 1.8V flash).
#define REMOTE_BUTTON_TABLE(X)                                                 \
  /* --- RTC-capable pins --- */                                               \
  X(0, "power")                                                                \
  X(2, "back")                                                                 \
  X(4, "home")                                                                 \
  X(12, "volume_up")                                                           \
  X(13, "mute")                                                                \
  X(14, "channel_up")                                                          \
  X(15, "volume_down")                                                         \
  X(25, "down")                                                                \
  X(26, "brightness_down")                                                     \
  X(27, "brightness_up")                                                       \
  X(32, "shortcut_3")                                                          \
  X(33, "shortcut_4")                                                          \
  X(34, "shortcut_1")                                                          \
  X(35, "shortcut_2")                                                          \
  /* --- non-RTC pins: work only while already awake --- */                     \
  X(5, "play_pause")                                                           \
  X(16, "settings")                                                            \
  X(17, "channel_down")                                                        \
  X(18, "up")                                                                  \
  X(19, "left")                                                                \
  X(22, "select_button")                                                       \
  X(23, "right")

// ---------------------------------------------------------------------------
// HOLD COMMANDS
// ---------------------------------------------------------------------------

// How long a button must be down before it counts as held rather than tapped.
// Overridable by device_config.h.
#ifndef HOLD_THRESHOLD_MS
#define HOLD_THRESHOLD_MS 500
#endif

// Buttons that send a second, distinct command when held instead of tapped.
// Keyed by tap command name, so a button's GPIO is never written down twice.
//
// A button listed here cannot fire on press: until the threshold passes or the
// button comes back up there is no telling a tap from a hold. The hold command
// fires the moment the threshold is crossed, and the tap command fires on
// release if it was not. Everything else still fires immediately on press.
//
// Held commands reach Home Assistant as a *long press of the base button*, so
// the automation editor shows one entry per physical button offering both.
//
// The tap name must exist in REMOTE_BUTTON_TABLE above;
// tools/check_discovery.sh enforces that.
#define REMOTE_HOLD_TABLE(X)                                                   \
  /*  tap command,      hold command */                                        \
  X("select_button", "select_button_held")
