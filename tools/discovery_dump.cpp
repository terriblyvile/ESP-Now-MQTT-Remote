// Host-side dump of everything a hub would publish, plus the tables the two
// firmwares share. Compiles on a normal machine -- no ESP toolchain -- because
// include/config.h, include/protocol.h and include/ha_discovery.h have no
// Arduino dependencies.
//
//   tools/check_discovery.sh
//
// Emits tab-separated rows, one per line, consumed by that script.

#include <cstdio>

#include "config.h"
#include "ha_discovery.h"
#include "protocol.h"

struct PinEntry {
  int pin;
  const char *name;
};

static const PinEntry kPinTable[] = {
#define X(pin, name) {pin, name},
    REMOTE_BUTTON_TABLE(X)
#undef X
};
static const size_t kPinCount = sizeof(kPinTable) / sizeof(kPinTable[0]);

struct HoldEntry {
  const char *tap;
  const char *hold;
};

static const HoldEntry kHoldTable[] = {
#define X(tap, hold) {tap, hold},
    REMOTE_HOLD_TABLE(X)
#undef X
};
static const size_t kHoldCount = sizeof(kHoldTable) / sizeof(kHoldTable[0]);

int main() {
  char topic[192];
  char payload[1024];
  char deviceJson[256];
  char nodeId[64];
  char stateTopic[128];

  printf("PACKET\t%zu\t%d\t%d\t%d\n", sizeof(RemotePacket),
         REMOTE_PROTOCOL_VERSION, MAX_LOCATION_LEN, MAX_COMMAND_LEN);
  printf("HUB\t%s\t%s\n", HUB_ID, HUB_NODE_ID);

  for (size_t i = 0; i < kPinCount; i++) {
    printf("PIN\t%d\t%s\n", kPinTable[i].pin, kPinTable[i].name);
  }

  for (size_t i = 0; i < kHoldCount; i++) {
    printf("HOLD\t%s\t%s\n", kHoldTable[i].tap, kHoldTable[i].hold);
  }

  for (size_t i = 0; i < kRemoteCount; i++) {
    printf("REMOTE\t%s\t%s\n", kRemotes[i].location, kRemotes[i].name);
  }

  for (size_t i = 0; i < kRetiredHubEntityCount; i++) {
    const HaRetiredEntity &r = kRetiredHubEntities[i];
    printf("RETIRED\t%s\t%s\t%s\n", r.nodeId ? r.nodeId : "-",
           r.objectId ? r.objectId : "-", r.stateTopic ? r.stateTopic : "-");
  }

  for (size_t i = 0; i < kRetiredRemoteEntityCount; i++) {
    printf("RETIRED_REMOTE\t%s\t%s\n", kRetiredRemoteEntities[i].objectId,
           kRetiredRemoteEntities[i].leaf);
  }

  // This hub's own diagnostics.
  for (size_t i = 0; i < kHubSensorCount; i++) {
    const HaHubSensorSpec &s = kHubSensors[i];
    haSensorTopic(topic, sizeof(topic), HUB_NODE_ID, s.objectId);
    int needed = haSensorPayload(payload, sizeof(payload), s.name, HUB_NODE_ID,
                                 s.objectId, s.stateTopic, s.extraJson,
                                 HA_HUB_AVAILABILITY_JSON, HA_HUB_DEVICE_JSON);
    printf("SENSOR\t%s\t%d\t%s\n", topic, needed, payload);
  }

  // One device per remote.
  for (size_t r = 0; r < kRemoteCount; r++) {
    const HaRemoteSpec &remote = kRemotes[r];

    remoteNodeId(nodeId, sizeof(nodeId), remote.location);
    haRemoteDeviceJson(deviceJson, sizeof(deviceJson), remote.location,
                       remote.name);
    remoteTopic(stateTopic, sizeof(stateTopic), remote.location, LEAF_COMMAND);

    for (size_t i = 0; i < kCommandCount; i++) {
      haTriggerTopic(topic, sizeof(topic), nodeId, kCommands[i].payload);
      int needed = haTriggerPayload(payload, sizeof(payload), kCommands[i],
                                    stateTopic, deviceJson);
      printf("TRIGGER\t%s\t%d\t%s\n", topic, needed, payload);
    }

    for (size_t i = 0; i < kRemoteSensorCount; i++) {
      const HaRemoteSensorSpec &s = kRemoteSensors[i];
      char sensorState[128];
      remoteTopic(sensorState, sizeof(sensorState), remote.location, s.leaf);
      haSensorTopic(topic, sizeof(topic), nodeId, s.objectId);
      int needed = haSensorPayload(payload, sizeof(payload), s.name, nodeId,
                                   s.objectId, sensorState, s.extraJson, NULL,
                                   deviceJson);
      printf("SENSOR\t%s\t%d\t%s\n", topic, needed, payload);
    }
  }

  return 0;
}
