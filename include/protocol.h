#pragma once

// The ESP-NOW wire format, shared by both build targets.
//
// Free of Arduino/ESP dependencies so tools/check_discovery.sh can compile and
// exercise it on a host machine.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "config.h"

// Bumped whenever the struct below changes shape. A hub rejects and logs any
// packet carrying a version it does not know, which turns "one remote silently
// stopped working after I flashed the other one" into a line in the log.
//
//   1  location + command + battery millivolts
//   2  battery monitoring removed
#define REMOTE_PROTOCOL_VERSION 2

// Packed so both ends agree on the layout byte for byte. Both are the same
// compiler and architecture today, but the wire format should not quietly
// depend on that staying true.
struct __attribute__((packed)) RemotePacket {
  uint8_t version;
  char location[MAX_LOCATION_LEN + 1];
  char command[MAX_COMMAND_LEN + 1];
};

// Fills a packet ready to transmit. Strings are truncated rather than
// overflowed, and the buffers are zeroed first so the trailing bytes carry no
// stack garbage over the air.
static inline void remotePacketInit(RemotePacket *packet, const char *location,
                                    const char *command) {
  memset(packet, 0, sizeof(*packet));
  packet->version = REMOTE_PROTOCOL_VERSION;
  strncpy(packet->location, location, MAX_LOCATION_LEN);
  strncpy(packet->command, command, MAX_COMMAND_LEN);
}

// Makes a received packet safe to read as C strings. Anything in radio range
// can send arbitrary bytes, so the terminators are forced rather than trusted
// before anything calls strcmp on these.
static inline void remotePacketTerminate(RemotePacket *packet) {
  packet->location[MAX_LOCATION_LEN] = '\0';
  packet->command[MAX_COMMAND_LEN] = '\0';
}
