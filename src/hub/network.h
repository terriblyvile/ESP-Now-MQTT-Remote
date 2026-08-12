#pragma once

// The hub's network transport, chosen at build time by HUB_USE_ETHERNET.
//
// ESP-NOW *is* WiFi: it rides the same radio. So the radio is powered up and
// listening in both builds. What the Ethernet build changes is only how the hub
// reaches the MQTT broker -- over a cable, with the radio doing nothing but
// ESP-NOW.
//
// That makes the Ethernet build the more robust of the two, for a reason worth
// spelling out. A WiFi hub associates with an access point, and the association
// dictates which channel its radio sits on. WIFI_CHANNEL is therefore only an
// *expectation* there, and a router that moves channel silently kills every
// button on every remote. An Ethernet hub never associates, so nothing can move
// it: it pins the radio to WIFI_CHANNEL at boot and stays there.
//
// Everything above this layer -- ESP-NOW handling, MQTT, discovery, battery
// routing -- is identical between the two.

#include <stddef.h>
#include <stdint.h>

#include "config.h"

// How long to wait before retrying a WiFi association. Unused on Ethernet,
// where the driver brings the link back by itself.
#define WIFI_RETRY_MS 10000

#if HUB_USE_ETHERNET
#define HUB_NETWORK_KIND "ethernet"
#define HUB_STATUS_TOPIC TOPIC_LINK
#else
#define HUB_NETWORK_KIND "wifi"
#define HUB_STATUS_TOPIC TOPIC_RSSI
#endif

// Powers up the radio for ESP-NOW and starts the transport. Must be called
// before esp_now_init(), which needs the radio already in station mode.
void hubNetworkBegin();

// Drives reconnection. Call from loop().
void hubNetworkTick();

// True once there is a usable address.
bool hubNetworkConnected();

// Logs address and link details, and warns if the ESP-NOW channel is not the
// one the remotes transmit on. Called on each transition to connected.
void hubNetworkLogStatus();

// The channel ESP-NOW is actually listening on, read back from the radio rather
// than assumed.
uint8_t hubNetworkChannel();

// Fills in the value for HUB_STATUS_TOPIC: signal strength in dBm on WiFi, link
// speed and duplex on Ethernet.
void hubNetworkStatusValue(char *out, size_t n);
