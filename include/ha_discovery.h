#pragma once

// Home Assistant MQTT discovery payload construction.
//
// Free of Arduino/ESP dependencies so the same code that runs on a hub can be
// compiled and exercised on a host machine -- run tools/check_discovery.sh to
// validate every payload without flashing anything.
//
// Every builder returns what snprintf returns: the length the payload *would*
// have needed. A value >= the buffer size means it was truncated.
//
// The device model has two independent halves. Each hub is a device carrying
// its own health, named after which hub it is, so a wired and a wireless one
// can run side by side. Each remote is a device of its own, named only after
// its room -- deliberately independent of any hub, because a remote is the same
// remote whichever base station happened to hear it, and either hub may be the
// one that publishes it.

#include <stddef.h>
#include <stdio.h>

#include "config.h"

// --- Remotes ---------------------------------------------------------------

struct HaRemoteSpec {
  const char *location; // topic segment, e.g. "livingroom"
  const char *name;     // what Home Assistant displays
};

static const HaRemoteSpec kRemotes[] = {
#define X(location, name) {location, name},
    REMOTE_LOCATION_TABLE(X)
#undef X
};

static const size_t kRemoteCount = sizeof(kRemotes) / sizeof(kRemotes[0]);

// --- Commands --------------------------------------------------------------
//
// Every payload a hub accepts, and how each one surfaces in Home Assistant.
// This doubles as the whitelist: anything not listed here never reaches MQTT.
//
// A tap is a short press of itself. A hold is a *long press of the button it
// belongs to* -- so `select_button_held` is reported as a long press with
// subtype `select_button`, and the automation editor offers "short press" and
// "long press" under one physical button rather than inventing a second one.
struct HaCommandSpec {
  const char *payload; // exact string the remote sends over ESP-NOW
  const char *type;    // Home Assistant device trigger type
  const char *subtype; // the physical button it belongs to
};

static const HaCommandSpec kCommands[] = {
#define X(pin, name) {name, "button_short_press", name},
    REMOTE_BUTTON_TABLE(X)
#undef X
#define X(tap, hold) {hold, "button_long_press", tap},
        REMOTE_HOLD_TABLE(X)
#undef X
};

static const size_t kCommandCount = sizeof(kCommands) / sizeof(kCommands[0]);

// --- Topics and ids --------------------------------------------------------

// home/<location>/remote/<leaf>
static inline int remoteTopic(char *out, size_t n, const char *location,
                              const char *leaf) {
  return snprintf(out, n, TOPIC_ROOT "/%s/" TOPIC_REMOTE_SEGMENT "/%s",
                  location, leaf);
}

static inline int remoteNodeId(char *out, size_t n, const char *location) {
  return snprintf(out, n, REMOTE_NODE_PREFIX "_%s", location);
}

// --- Shared JSON fragments -------------------------------------------------

// A hub's own entities go unavailable with it, via its last will.
#define HA_HUB_AVAILABILITY_JSON                                               \
  "\"availability_topic\":\"" TOPIC_STATUS "\",\"payload_available\":\""       \
  PAYLOAD_ONLINE "\",\"payload_not_available\":\"" PAYLOAD_OFFLINE "\""

#define HA_HUB_DEVICE_JSON                                                     \
  "\"device\":{\"identifiers\":[\"" HUB_NODE_ID "\"],\"name\":\""              \
  HUB_FRIENDLY_NAME "\",\"manufacturer\":\"DIY\",\"model\":\"ESP-NOW to MQTT " \
  "Bridge\",\"sw_version\":\"" FIRMWARE_VERSION "\"}"

// Remote entities carry no availability, and no via_device. Both would have to
// name one particular hub, and with two hubs running that is wrong: a remote
// served by the wired hub would be marked unavailable whenever the wireless one
// went down, or vice versa. A remote has no online/offline state of its own
// anyway -- it is asleep almost all the time.
static inline int haRemoteDeviceJson(char *out, size_t n, const char *location,
                                     const char *name) {
  return snprintf(out, n,
                  "\"device\":{\"identifiers\":[\"" REMOTE_NODE_PREFIX
                  "_%s\"],\"name\":\"%s\",\"manufacturer\":\"DIY\",\"model\":"
                  "\"ESP-NOW Remote\",\"sw_version\":\"" FIRMWARE_VERSION "\"}",
                  location, name);
}

// --- Device triggers -------------------------------------------------------
//
// One per command per remote. These are what surface in the HA automation
// editor under "Device". Device triggers carry no availability or unique_id: HA
// keys them on the topic/type/subtype triple.

static inline int haTriggerTopic(char *out, size_t n, const char *nodeId,
                                 const char *command) {
  return snprintf(out, n,
                  HA_DISCOVERY_PREFIX "/device_automation/%s/%s/config", nodeId,
                  command);
}

static inline int haTriggerPayload(char *out, size_t n,
                                   const HaCommandSpec &command,
                                   const char *commandTopic,
                                   const char *deviceJson) {
  return snprintf(out, n,
                  "{\"automation_type\":\"trigger\",\"type\":\"%s\",\"subtype\":"
                  "\"%s\",\"topic\":\"%s\",\"payload\":\"%s\",%s}",
                  command.type, command.subtype, commandTopic, command.payload,
                  deviceJson);
}

// --- Sensors ---------------------------------------------------------------

static inline int haSensorTopic(char *out, size_t n, const char *nodeId,
                                const char *objectId) {
  return snprintf(out, n, HA_DISCOVERY_PREFIX "/sensor/%s/%s/config", nodeId,
                  objectId);
}

// `extraJson` and `availabilityJson` are spliced in verbatim as bare JSON
// fragments with no leading or trailing comma; either may be NULL.
static inline int haSensorPayload(char *out, size_t n, const char *name,
                                  const char *nodeId, const char *objectId,
                                  const char *stateTopic, const char *extraJson,
                                  const char *availabilityJson,
                                  const char *deviceJson) {
  const bool hasExtra = extraJson != NULL && extraJson[0] != '\0';
  const bool hasAvail = availabilityJson != NULL && availabilityJson[0] != '\0';
  return snprintf(out, n,
                  "{\"name\":\"%s\",\"unique_id\":\"%s_%s\",\"state_topic\":"
                  "\"%s\",%s%s%s%s%s}",
                  name, nodeId, objectId, stateTopic,
                  hasExtra ? extraJson : "", hasExtra ? "," : "",
                  hasAvail ? availabilityJson : "", hasAvail ? "," : "",
                  deviceJson);
}

// A hub's own health. State topics are fixed and already carry the hub id.
struct HaHubSensorSpec {
  const char *name;
  const char *objectId;
  const char *stateTopic;
  const char *extraJson;
};

static const HaHubSensorSpec kHubSensors[] = {
#if HUB_USE_ETHERNET
    // No signal strength over a cable; link speed and duplex are the
    // equivalent health check.
    {"Ethernet Link", "link", TOPIC_LINK,
     "\"icon\":\"mdi:ethernet\",\"entity_category\":\"diagnostic\""},
#else
    {"WiFi Signal", "rssi", TOPIC_RSSI,
     "\"device_class\":\"signal_strength\",\"unit_of_measurement\":\"dBm\","
     "\"state_class\":\"measurement\",\"entity_category\":\"diagnostic\""},
#endif
    // If this stops matching WIFI_CHANNEL, ESP-NOW has gone deaf and no button
    // on any remote served by this hub will work.
    {"ESP-NOW Channel", "channel", TOPIC_CHANNEL,
     "\"icon\":\"mdi:wifi\",\"entity_category\":\"diagnostic\""},
    {"Uptime", "uptime", TOPIC_UPTIME,
     "\"device_class\":\"duration\",\"unit_of_measurement\":\"s\",\"state_"
     "class\":\"total_increasing\",\"entity_category\":\"diagnostic\""},
};

static const size_t kHubSensorCount =
    sizeof(kHubSensors) / sizeof(kHubSensors[0]);

// Per-remote entities. `leaf` is appended to that remote's topic branch, so the
// same table serves every location.
struct HaRemoteSensorSpec {
  const char *name;
  const char *objectId;
  const char *leaf;
  const char *extraJson;
};

static const HaRemoteSensorSpec kRemoteSensors[] = {
    {"Last Command", "last_command", LEAF_LAST_COMMAND,
     "\"icon\":\"mdi:remote\""},
};

static const size_t kRemoteSensorCount =
    sizeof(kRemoteSensors) / sizeof(kRemoteSensors[0]);

// --- Retirements -----------------------------------------------------------
//
// Discovery is retained, which is what lets Home Assistant rediscover
// everything after a restart -- but it also means an entity simply no longer
// announced lingers forever, frozen at its last value. HA deletes an entity
// when its config topic is published empty, so retirements must be named.
//
// Add here whenever an entity is removed, renamed or moved between devices, and
// never name something this build still publishes -- tools/check_discovery.sh
// enforces that.

struct HaRetiredEntity {
  const char *nodeId;     // NULL: nothing to un-announce, just a stale topic
  const char *objectId;
  const char *stateTopic; // NULL: that topic is still in use elsewhere
};

static const HaRetiredEntity kRetiredHubEntities[] = {
    // Before hubs had ids, there was one hub device on one topic branch. Both
    // moved so a wired and a wireless hub could coexist.
    {"esp_hub", "rssi", TOPIC_ROOT "/hub/rssi"},
    {"esp_hub", "link", TOPIC_ROOT "/hub/link"},
    {"esp_hub", "channel", TOPIC_ROOT "/hub/channel"},
    {"esp_hub", "uptime", TOPIC_ROOT "/hub/uptime"},
    {NULL, NULL, TOPIC_ROOT "/hub/status"},
    // Hub-level until each remote became its own device. Its old state topic is
    // now a live per-remote topic, so only the config is cleared.
    {"esp_hub", "last_command", NULL},
    // Whichever link-health sensor this transport does not publish.
#if HUB_USE_ETHERNET
    {HUB_NODE_ID, "rssi", TOPIC_RSSI},
#else
    {HUB_NODE_ID, "link", TOPIC_LINK},
#endif
};

static const size_t kRetiredHubEntityCount =
    sizeof(kRetiredHubEntities) / sizeof(kRetiredHubEntities[0]);

// Retired on every remote, for every location.
struct HaRetiredRemoteEntity {
  const char *objectId;
  const char *leaf;
};

static const HaRetiredRemoteEntity kRetiredRemoteEntities[] = {
    // Battery monitoring, removed in 2.0.0.
    {"battery", "battery"},
    {"battery_voltage", "battery_voltage"},
};

static const size_t kRetiredRemoteEntityCount =
    sizeof(kRetiredRemoteEntities) / sizeof(kRetiredRemoteEntities[0]);
