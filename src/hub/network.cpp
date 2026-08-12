#include "network.h"

#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>

#include "secrets.h"

// Puts the radio into station mode for ESP-NOW and disables power save. With
// modem sleep on, the radio powers down between beacons and quietly misses
// inbound packets, which looks exactly like a remote with a flat battery.
static void startRadio() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  esp_wifi_set_ps(WIFI_PS_NONE);
}

uint8_t hubNetworkChannel() {
  uint8_t primary = 0;
  wifi_second_chan_t second = WIFI_SECOND_CHAN_NONE;
  esp_wifi_get_channel(&primary, &second);
  return primary;
}

#if HUB_USE_ETHERNET

// ---------------------------------------------------------------------------
// ETHERNET (WT32-ETH01)
// ---------------------------------------------------------------------------
//
// Pin assignments come from the wt32-eth01 variant in the Arduino core --
// LAN8720 PHY at address 1, power on GPIO 16, MDC 23, MDIO 18, and a 50MHz
// clock fed in on GPIO 0 -- so ETH.begin() needs no arguments here.

#include <ETH.h>

static volatile bool ethHasAddress = false;

static void onNetworkEvent(WiFiEvent_t event) {
  switch (event) {
  case ARDUINO_EVENT_ETH_START:
    // Sets the DHCP client name, and the name OTA is reachable at.
    ETH.setHostname(HUB_NODE_ID);
    Serial.println("[eth] started");
    break;
  case ARDUINO_EVENT_ETH_CONNECTED:
    Serial.println("[eth] link up");
    break;
  case ARDUINO_EVENT_ETH_GOT_IP:
    ethHasAddress = true;
    break;
  case ARDUINO_EVENT_ETH_DISCONNECTED:
    ethHasAddress = false;
    Serial.println("[eth] link down");
    break;
  case ARDUINO_EVENT_ETH_STOP:
    ethHasAddress = false;
    Serial.println("[eth] stopped");
    break;
  default:
    break;
  }
}

void hubNetworkBegin() {
  // The radio comes up even though nothing here joins a WiFi network: ESP-NOW
  // has no transport of its own.
  startRadio();

  // Make sure a previously stored access point cannot pull the radio onto some
  // other channel behind our back.
  WiFi.disconnect(false, false);

  // Nothing will ever move the channel now, so set it once and it stays. This
  // is the whole reason the Ethernet build is steadier than the WiFi one.
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);

  WiFi.onEvent(onNetworkEvent);
  ETH.begin();
}

void hubNetworkTick() {
  // Driven entirely by the event handler; the driver brings the link back on
  // its own when the cable is replugged.
}

bool hubNetworkConnected() { return ethHasAddress && ETH.linkUp(); }

void hubNetworkLogStatus() {
  Serial.printf("[eth] up: ip=%s %uMbps %s-duplex\n",
                ETH.localIP().toString().c_str(), ETH.linkSpeed(),
                ETH.fullDuplex() ? "full" : "half");

  const uint8_t channel = hubNetworkChannel();
  if (channel == WIFI_CHANNEL) {
    Serial.printf("[espnow] listening on channel %u, pinned -- no access point "
                  "association can move it\n",
                  channel);
  } else {
    // Should be unreachable: nothing associates, so nothing retunes the radio.
    Serial.printf("[espnow] *** channel is %u but WIFI_CHANNEL is %d; remotes "
                  "will not be heard ***\n",
                  channel, WIFI_CHANNEL);
  }
}

void hubNetworkStatusValue(char *out, size_t n) {
  if (!ETH.linkUp()) {
    snprintf(out, n, "down");
    return;
  }
  snprintf(out, n, "%uM %s", ETH.linkSpeed(), ETH.fullDuplex() ? "full" : "half");
}

#else

// ---------------------------------------------------------------------------
// WIFI
// ---------------------------------------------------------------------------

void hubNetworkBegin() {
  startRadio();
  WiFi.setAutoReconnect(true);
  Serial.printf("[wifi] connecting to %s\n", WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
}

void hubNetworkTick() {
  static uint32_t lastAttempt = 0;

  if (WiFi.status() == WL_CONNECTED) {
    return;
  }
  if (lastAttempt != 0 && millis() - lastAttempt < WIFI_RETRY_MS) {
    return;
  }
  lastAttempt = millis();

  Serial.printf("[wifi] reconnecting to %s\n", WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
}

bool hubNetworkConnected() { return WiFi.status() == WL_CONNECTED; }

void hubNetworkLogStatus() {
  const uint8_t channel = hubNetworkChannel();

  Serial.printf("[wifi] connected: ip=%s rssi=%d channel=%u\n",
                WiFi.localIP().toString().c_str(), WiFi.RSSI(), channel);

  if (channel != WIFI_CHANNEL) {
    // Associating with an access point is what sets the channel, so this is a
    // real possibility here in a way it is not on the Ethernet build.
    Serial.printf("[wifi] *** CHANNEL MISMATCH: the remotes transmit on %d but "
                  "this hub is on %u. ESP-NOW packets will NOT arrive. Lock "
                  "your AP to channel %d, change WIFI_CHANNEL in "
                  "include/config.h to %u, or move the hub to Ethernet where "
                  "the channel cannot drift. ***\n",
                  WIFI_CHANNEL, channel, WIFI_CHANNEL, channel);
  }
}

void hubNetworkStatusValue(char *out, size_t n) {
  snprintf(out, n, "%d", WiFi.RSSI());
}

#endif
