// Base station: receives ESP-NOW packets from every remote and republishes them
// to MQTT for Home Assistant. Native replacement for the old ESPHome hub.yaml.
//
// Several remotes share this one hub. Each packet carries the location of the
// remote that sent it, so the hub routes to home/<location>/remote/* without
// needing any per-remote configuration -- no MAC addresses to register. The
// list of valid locations in config.h is what it validates against.
//
// Mapping from the ESPHome config this replaces:
//   wifi:              -> ensureWifi()
//   mqtt:              -> PubSubClient + ensureMqtt(), same broker and topics
//   mqtt: discovery    -> publishDiscovery(), one HA device per remote
//   espnow: on_receive -> onEspNowRecv() -> queue -> drainCommandQueue()
//   ota:               -> ArduinoOTA
//   logger:            -> Serial
//   api: reboot_timeout -> gone; that was an ESPHome-only watchdog

#include <Arduino.h>
#include <ArduinoOTA.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <esp_idf_version.h>
#include <esp_now.h>
#include <esp_timer.h>
#include <esp_wifi.h>

#include "config.h"
#include "ha_discovery.h"
#include "network.h"
#include "protocol.h"
#include "secrets.h"

// ---------------------------------------------------------------------------
// TUNABLES
// ---------------------------------------------------------------------------

#define COMMAND_QUEUE_DEPTH 16
#define MQTT_RETRY_MS 5000

// How often to say "still here, still waiting" while there is no link.
//
// Without this the hub is completely silent whenever it cannot reach the
// network -- an unplugged cable looks exactly like a boot loop or a dead board
// on the serial console, and the only proof of life is a boot log you have to
// catch in the instant after reset.
#define NETWORK_WAIT_LOG_MS 10000
#define DIAGNOSTIC_INTERVAL_MS 60000
#define MQTT_BUFFER_SIZE 1024

// A button press that could not be delivered within this window is dropped
// rather than replayed. Firing "power" two minutes late is worse than not
// firing it at all.
#define COMMAND_MAX_AGE_MS 5000

// ---------------------------------------------------------------------------
// WHITELISTS
// ---------------------------------------------------------------------------

// ESP-NOW here is unencrypted and unauthenticated, so anything in radio range
// can hand us a packet. Both the command and the location it claims to come
// from are checked against what we know about before anything reaches MQTT --
// otherwise a stranger could publish arbitrary strings, or invent a room and
// have us create topics for it. Both lists live in ha_discovery.h alongside how
// they are announced to Home Assistant, so the whitelists and the discovery can
// never disagree.
static bool isKnownCommand(const char *text) {
  for (size_t i = 0; i < kCommandCount; i++) {
    if (strcmp(text, kCommands[i].payload) == 0) {
      return true;
    }
  }
  return false;
}

static const HaRemoteSpec *findRemote(const char *location) {
  for (size_t i = 0; i < kRemoteCount; i++) {
    if (strcmp(location, kRemotes[i].location) == 0) {
      return &kRemotes[i];
    }
  }
  return NULL;
}

// ---------------------------------------------------------------------------
// STATE
// ---------------------------------------------------------------------------

struct RxCommand {
  RemotePacket packet;
  uint8_t mac[6];
  uint32_t rxMillis;
};

static QueueHandle_t commandQueue = nullptr;

static WiFiClient netClient;
static PubSubClient mqtt(netClient);

static char mqttClientId[32];
static bool otaStarted = false;

// Written from the WiFi task, read from loop(). Diagnostics only, so a torn
// increment is not worth a critical section.
static volatile uint32_t droppedQueueFull = 0;
static volatile uint32_t rejectedUnknown = 0;
static volatile uint32_t rejectedMalformed = 0;
static volatile uint32_t rejectedVersion = 0;
static volatile uint32_t rejectedLocation = 0;

// ---------------------------------------------------------------------------
// ESP-NOW
// ---------------------------------------------------------------------------

// The callback signature changed in Arduino-ESP32 3.x / IDF 5.x. This project
// currently builds against 2.0.6 / IDF 4.4, but keep both paths so a core
// upgrade does not silently break the build.
#if ESP_IDF_VERSION_MAJOR >= 5
static void onEspNowRecv(const esp_now_recv_info_t *info, const uint8_t *data,
                         int len) {
  const uint8_t *mac = info->src_addr;
#else
static void onEspNowRecv(const uint8_t *mac, const uint8_t *data, int len) {
#endif
  // Runs on the WiFi task. Do the cheap validation here and hand off; MQTT
  // publishing from this context would block the radio.
  if (len != (int)sizeof(RemotePacket)) {
    rejectedMalformed++;
    return;
  }

  RxCommand cmd;
  memcpy(&cmd.packet, data, sizeof(RemotePacket));

  // Force the string terminators before anything treats these as C strings.
  // The bytes came off the air and nothing about them is trustworthy.
  remotePacketTerminate(&cmd.packet);

  if (cmd.packet.version != REMOTE_PROTOCOL_VERSION) {
    rejectedVersion++;
    return;
  }
  if (findRemote(cmd.packet.location) == NULL) {
    rejectedLocation++;
    return;
  }
  if (!isKnownCommand(cmd.packet.command)) {
    rejectedUnknown++;
    return;
  }

  memcpy(cmd.mac, mac, 6);
  cmd.rxMillis = millis();

  if (xQueueSend(commandQueue, &cmd, 0) != pdTRUE) {
    droppedQueueFull++;
  }
}

static void setupEspNow() {
  // Register the callback only once there is somewhere for it to put packets,
  // so it can never run against a null queue.
  if (commandQueue == nullptr) {
    Serial.println("[espnow] no command queue, receiver not started");
    return;
  }
  if (esp_now_init() != ESP_OK) {
    Serial.println("[espnow] init failed");
    return;
  }
  esp_now_register_recv_cb(onEspNowRecv);

  // No peer registration needed: receiving works without one, and this hub
  // never transmits. That covers what ESPHome's `auto_add_peer: true` bought us
  // here -- the remote's MAC never has to be configured on this end.
  Serial.println("[espnow] listening");
}

// ---------------------------------------------------------------------------
// NETWORK
// ---------------------------------------------------------------------------

// Whether the transport is WiFi or Ethernet is decided in network.cpp. This
// only watches for the transition to connected, which is when OTA can start and
// the link details are worth logging.
static void serviceNetwork() {
  static bool wasConnected = false;

  hubNetworkTick();

  if (hubNetworkConnected()) {
    if (!wasConnected) {
      wasConnected = true;
      hubNetworkLogStatus();

      if (!otaStarted) {
        ArduinoOTA.setHostname(HUB_NODE_ID);
        ArduinoOTA.setPassword(OTA_PASSWORD);
        ArduinoOTA.onStart([]() { Serial.println("[ota] start"); });
        ArduinoOTA.onEnd([]() { Serial.println("[ota] done"); });
        ArduinoOTA.begin();
        otaStarted = true;
      }
    }
    return;
  }

  if (wasConnected) {
    wasConnected = false;
    Serial.println("[net] lost connection");
  }

  // Proof of life while disconnected, and it carries the two facts worth
  // knowing at that point: that the firmware is running at all, and which
  // channel ESP-NOW ended up on.
  static uint32_t lastWaitLog = 0;
  if (lastWaitLog == 0 || millis() - lastWaitLog >= NETWORK_WAIT_LOG_MS) {
    lastWaitLog = millis();
    Serial.printf("[net] " HUB_NETWORK_KIND ": no connection yet, up %us, "
                  "ESP-NOW listening on channel %u\n",
                  (unsigned)(esp_timer_get_time() / 1000000ULL),
                  hubNetworkChannel());
  }
}

// ---------------------------------------------------------------------------
// MQTT
// ---------------------------------------------------------------------------

// Publishes retained, so Home Assistant re-reads it after an HA restart without
// this hub having to do anything.
static bool publishConfig(const char *topic, const char *payload, int needed) {
  if (needed < 0 || (size_t)needed >= MQTT_BUFFER_SIZE) {
    Serial.printf("[mqtt] discovery payload for %s truncated (%d bytes)\n",
                  topic, needed);
    return false;
  }
  if (!mqtt.publish(topic, payload, true)) {
    Serial.printf("[mqtt] publish failed for %s\n", topic);
    return false;
  }
  delay(5); // let the stack drain between retained publishes
  return true;
}

static void publishDiscovery() {
  static char topic[192];
  static char payload[MQTT_BUFFER_SIZE];
  static char deviceJson[256];
  static char nodeId[64];
  static char stateTopic[128];

  unsigned published = 0;
  const unsigned expected =
      (unsigned)(kHubSensorCount +
                 kRemoteCount * (kCommandCount + kRemoteSensorCount));

  // Retract anything earlier firmware announced and this build does not, before
  // announcing what it does. An empty retained payload on a config topic is how
  // Home Assistant is told to delete an entity; without this, switching
  // transports leaves a dead WiFi Signal sensor frozen at its last reading.
  for (size_t i = 0; i < kRetiredHubEntityCount; i++) {
    const HaRetiredEntity &retired = kRetiredHubEntities[i];

    if (retired.nodeId != NULL) {
      haSensorTopic(topic, sizeof(topic), retired.nodeId, retired.objectId);
      mqtt.publish(topic, "", true);
    }

    // Clear the stale reading too, so nothing is left holding a value that
    // will never be updated again.
    if (retired.stateTopic != NULL) {
      mqtt.publish(retired.stateTopic, "", true);
    }
    delay(5);
  }

  // This hub's own health, on its own device.
  for (size_t i = 0; i < kHubSensorCount; i++) {
    const HaHubSensorSpec &s = kHubSensors[i];
    haSensorTopic(topic, sizeof(topic), HUB_NODE_ID, s.objectId);
    int needed = haSensorPayload(payload, sizeof(payload), s.name, HUB_NODE_ID,
                                 s.objectId, s.stateTopic, s.extraJson,
                                 HA_HUB_AVAILABILITY_JSON, HA_HUB_DEVICE_JSON);
    published += publishConfig(topic, payload, needed) ? 1 : 0;
  }

  // Then one device per remote. Published for every configured location whether
  // or not that remote has ever been heard from -- the table in config.h is the
  // statement of which remotes exist.
  //
  // With two hubs running, both publish these, identically. That is harmless:
  // the payloads are byte for byte the same and retained, so whichever writes
  // last leaves the same result.
  for (size_t r = 0; r < kRemoteCount; r++) {
    const HaRemoteSpec &remote = kRemotes[r];

    remoteNodeId(nodeId, sizeof(nodeId), remote.location);
    haRemoteDeviceJson(deviceJson, sizeof(deviceJson), remote.location,
                       remote.name);
    remoteTopic(stateTopic, sizeof(stateTopic), remote.location, LEAF_COMMAND);

    for (size_t i = 0; i < kRetiredRemoteEntityCount; i++) {
      const HaRetiredRemoteEntity &retired = kRetiredRemoteEntities[i];
      char retiredState[128];
      remoteTopic(retiredState, sizeof(retiredState), remote.location,
                  retired.leaf);
      haSensorTopic(topic, sizeof(topic), nodeId, retired.objectId);
      mqtt.publish(topic, "", true);
      mqtt.publish(retiredState, "", true);
      delay(5);
    }

    for (size_t i = 0; i < kCommandCount; i++) {
      haTriggerTopic(topic, sizeof(topic), nodeId, kCommands[i].payload);
      int needed = haTriggerPayload(payload, sizeof(payload), kCommands[i],
                                    stateTopic, deviceJson);
      published += publishConfig(topic, payload, needed) ? 1 : 0;
    }

    for (size_t i = 0; i < kRemoteSensorCount; i++) {
      const HaRemoteSensorSpec &s = kRemoteSensors[i];
      char sensorState[128];
      remoteTopic(sensorState, sizeof(sensorState), remote.location, s.leaf);
      haSensorTopic(topic, sizeof(topic), nodeId, s.objectId);
      int needed = haSensorPayload(payload, sizeof(payload), s.name, nodeId,
                                   s.objectId, sensorState, s.extraJson, NULL,
                                   deviceJson);
      published += publishConfig(topic, payload, needed) ? 1 : 0;
    }
  }

  Serial.printf("[mqtt] discovery published: %u of %u entities, %u remote(s)\n",
                published, expected, (unsigned)kRemoteCount);
}

static void ensureMqtt() {
  static uint32_t lastAttempt = 0;

  if (mqtt.connected()) {
    return;
  }
  if (lastAttempt != 0 && millis() - lastAttempt < MQTT_RETRY_MS) {
    return;
  }
  lastAttempt = millis();

  Serial.printf("[mqtt] connecting to %s:%d\n", MQTT_HOST, MQTT_PORT);

  // Last will: if we drop off, HA marks every entity unavailable.
  bool ok = mqtt.connect(mqttClientId, MQTT_USERNAME, MQTT_PASSWORD,
                         TOPIC_STATUS, 0, true, PAYLOAD_OFFLINE);
  if (!ok) {
    Serial.printf("[mqtt] failed, rc=%d\n", mqtt.state());
    return;
  }

  Serial.println("[mqtt] connected");
  mqtt.publish(TOPIC_STATUS, PAYLOAD_ONLINE, true);
  publishDiscovery();
}

// ---------------------------------------------------------------------------
// MAIN FLOW
// ---------------------------------------------------------------------------

static void drainCommandQueue() {
  RxCommand cmd;
  char topic[128];

  if (commandQueue == nullptr) {
    return;
  }

  while (mqtt.connected() && xQueueReceive(commandQueue, &cmd, 0) == pdTRUE) {
    uint32_t age = millis() - cmd.rxMillis;
    if (age > COMMAND_MAX_AGE_MS) {
      Serial.printf("[cmd] dropping stale '%s' from %s (%ums old)\n",
                    cmd.packet.command, cmd.packet.location, (unsigned)age);
      continue;
    }

    Serial.printf("[cmd] %s [%s] from %02X:%02X:%02X:%02X:%02X:%02X\n",
                  cmd.packet.command, cmd.packet.location, cmd.mac[0],
                  cmd.mac[1], cmd.mac[2], cmd.mac[3], cmd.mac[4], cmd.mac[5]);

    // Not retained: this is an event. HA device triggers fire on the message
    // itself, and a retained press would re-fire on every HA restart.
    remoteTopic(topic, sizeof(topic), cmd.packet.location, LEAF_COMMAND);
    mqtt.publish(topic, cmd.packet.command, false);

    // Retained mirror so the sensor still reads correctly after a restart.
    remoteTopic(topic, sizeof(topic), cmd.packet.location, LEAF_LAST_COMMAND);
    mqtt.publish(topic, cmd.packet.command, true);
  }
}

static void publishDiagnostics() {
  static uint32_t lastPublish = 0;

  if (!mqtt.connected()) {
    return;
  }
  if (lastPublish != 0 && millis() - lastPublish < DIAGNOSTIC_INTERVAL_MS) {
    return;
  }
  lastPublish = millis();

  char value[16];

  // Signal strength on WiFi, link speed and duplex on Ethernet. Only whichever
  // one this build announced in discovery is ever published.
  hubNetworkStatusValue(value, sizeof(value));
  mqtt.publish(HUB_STATUS_TOPIC, value, true);

  snprintf(value, sizeof(value), "%u", hubNetworkChannel());
  mqtt.publish(TOPIC_CHANNEL, value, true);

  snprintf(value, sizeof(value), "%u",
           (unsigned)(esp_timer_get_time() / 1000000ULL));
  mqtt.publish(TOPIC_UPTIME, value, true);

  if (droppedQueueFull || rejectedUnknown || rejectedMalformed ||
      rejectedVersion || rejectedLocation) {
    // rejected_version climbing means a remote is still running the old bare
    // string protocol, or a newer one than this hub -- reflash it.
    Serial.printf("[diag] dropped=%u rejected: command=%u malformed=%u "
                  "version=%u location=%u\n",
                  (unsigned)droppedQueueFull, (unsigned)rejectedUnknown,
                  (unsigned)rejectedMalformed, (unsigned)rejectedVersion,
                  (unsigned)rejectedLocation);
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.printf("\n[boot] " HUB_FRIENDLY_NAME " " FIRMWARE_VERSION
                " over " HUB_NETWORK_KIND
                ", protocol v%d, %u remote(s), %u command(s)\n",
                REMOTE_PROTOCOL_VERSION, (unsigned)kRemoteCount,
                (unsigned)kCommandCount);

  commandQueue = xQueueCreate(COMMAND_QUEUE_DEPTH, sizeof(RxCommand));
  if (commandQueue == nullptr) {
    Serial.println("[boot] FATAL: could not allocate the command queue");
  }

  // Powers up the radio and starts the transport. Has to happen first:
  // esp_now_init() needs the radio already in station mode.
  hubNetworkBegin();

  // Bring the receiver up before the link is necessarily usable, so presses
  // made while DHCP is still running are queued rather than lost.
  setupEspNow();

  // The WiFi MAC, which is the address remotes unicast to -- not the Ethernet
  // MAC, which is a different address on the Ethernet build and is no use here.
  uint8_t mac[6];
  WiFi.macAddress(mac);
  snprintf(mqttClientId, sizeof(mqttClientId), HUB_NODE_ID "-%02X%02X%02X",
           mac[3], mac[4], mac[5]);
  Serial.printf("[boot] client_id=%s\n", mqttClientId);
  Serial.printf("[boot] ESP-NOW address %02X:%02X:%02X:%02X:%02X:%02X"
                " -- this is what HUB_MAC_ADDRESS in include/config.h must be"
                " set to, and every remote reflashed, if you change hubs\n",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(MQTT_BUFFER_SIZE); // discovery payloads exceed the 256B default
  mqtt.setKeepAlive(30);
}

void loop() {
  serviceNetwork();

  if (hubNetworkConnected()) {
    ArduinoOTA.handle();
    ensureMqtt();
    mqtt.loop();
  }

  drainCommandQueue();
  publishDiagnostics();

  delay(5);
}
