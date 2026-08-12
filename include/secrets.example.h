#pragma once

// Copy to include/secrets.h and fill in. secrets.h is gitignored.
//
//   cp include/secrets.example.h include/secrets.h
//
// Only the `hub` target uses these; the remote never joins WiFi.

#define WIFI_SSID "your-ssid"
#define WIFI_PASSWORD "your-wifi-password"

#define MQTT_HOST "192.168.1.10"
#define MQTT_PORT 1883
#define MQTT_USERNAME "mqtt-user"
#define MQTT_PASSWORD "mqtt-password"

// Password for over-the-air updates (pio run -e hub -t upload --upload-port <ip>).
#define OTA_PASSWORD "change-me"
