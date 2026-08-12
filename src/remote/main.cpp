// Battery handset: reads buttons, sends the pressed command to a base station
// over ESP-NOW, then light-sleeps until the next press.
//
// The button table, the target MAC and the radio channel all come from
// include/config.h, which the hub build shares -- so a button added there shows
// up in Home Assistant without touching either firmware.
//
// Which remote this is gets baked in at build time as REMOTE_LOCATION, set by
// the matching platformio.ini environment, and travels in every packet. The hub
// uses it to decide which room's topics to publish to, so several remotes can
// share one base station without it needing to know any of their MACs.

#include <Arduino.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_sleep.h>
#include <esp_wifi.h>

#include "config.h"
#include "protocol.h"

// Sleep after this much inactivity.
#define SLEEP_TIMEOUT_MS 10000

// ---------------------------------------------------------------------------
// PIN DEFINITIONS
// ---------------------------------------------------------------------------

struct Button {
  uint8_t pin;
  const char *name;
};

static const Button buttons[] = {
#define X(pin, name) {pin, name},
    REMOTE_BUTTON_TABLE(X)
#undef X
};

static const int buttonCount = sizeof(buttons) / sizeof(buttons[0]);

// Buttons that send a different command when held. See REMOTE_HOLD_TABLE.
struct HoldCommand {
  const char *tap;
  const char *hold;
};

static const HoldCommand holdCommands[] = {
#define X(tap, hold) {tap, hold},
    REMOTE_HOLD_TABLE(X)
#undef X
};

static const int holdCommandCount =
    sizeof(holdCommands) / sizeof(holdCommands[0]);

// Returns the hold command for a button, or NULL if it has no hold behaviour.
static const char *holdCommandFor(const char *tapCommand) {
  for (int i = 0; i < holdCommandCount; i++) {
    if (strcmp(tapCommand, holdCommands[i].tap) == 0) {
      return holdCommands[i].hold;
    }
  }
  return NULL;
}

static uint8_t broadcastAddress[] = HUB_MAC_ADDRESS;

static unsigned long lastActivity = 0;

// ---------------------------------------------------------------------------
// ESP-NOW CALLBACKS
// ---------------------------------------------------------------------------
void OnDataSent(const uint8_t *mac_addr, esp_now_send_status_t status) {
  Serial.print("Last Packet Send Status: ");
  Serial.println(status == ESP_NOW_SEND_SUCCESS ? "Delivery Success"
                                                : "Delivery Fail");
}

// Forward Declarations
void checkButtons();
void handlePress(int index, unsigned long pressedAt);
void sendCmd(const char *cmd);
void goToSleep();
void setupESPNow();

void setup() {
  Serial.begin(115200);
  delay(1000); // Give serial monitor time to catch up
  Serial.printf("Booting... [%s] protocol v%d\n", REMOTE_LOCATION,
                REMOTE_PROTOCOL_VERSION);


  // 2. Setup Pins
  // Note: GPIO 34-39 are input only and cannot have internal pullups.
  // You MUST have physical resistors on them or this won't work.
  for (int i = 0; i < buttonCount; i++) {
    if (buttons[i].pin >= 34) {
      pinMode(buttons[i].pin, INPUT);
    } else {
      pinMode(buttons[i].pin, INPUT_PULLUP);
    }
  }

  setupESPNow();

  // 7. Check Wakeup Cause
  // If we woke up from light sleep, we continue execution here.
  // But if we just booted, we might want to check buttons too.
  checkButtons();

  lastActivity = millis();
}

void setupESPNow() {
  // 3. Init WiFi in Station Mode (No connection, just radio on)
  WiFi.mode(WIFI_STA);
  esp_wifi_set_ps(WIFI_PS_NONE); // Disable WiFi Power Save for responsiveness

  // 4. Force Channel (Critical for ESP-NOW)
  // We use a trick to set the channel without connecting to an AP
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);

  // 5. Init ESP-NOW
  if (esp_now_init() != ESP_OK) {
    Serial.println("Error initializing ESP-NOW");
    return;
  }
  esp_now_register_send_cb(OnDataSent);

  // 6. Register Peer (Base Station)
  esp_now_peer_info_t peerInfo;
  memset(&peerInfo, 0, sizeof(peerInfo));
  memcpy(peerInfo.peer_addr, broadcastAddress, 6);
  peerInfo.channel = WIFI_CHANNEL;
  peerInfo.encrypt = false;
  peerInfo.ifidx = WIFI_IF_STA;

  if (esp_now_add_peer(&peerInfo) != ESP_OK) {
    Serial.println("Failed to add peer");
    return;
  }
}

void loop() {
  // 1. Check all buttons constantly
  checkButtons();

  // 2. Check for Sleep Timeout
  if (millis() - lastActivity > SLEEP_TIMEOUT_MS) {
    goToSleep();
  }

  // Small delay to debounce
  delay(10);
}

void checkButtons() {
  for (int i = 0; i < buttonCount; i++) {
    // Read pin. Low = Pressed (because input_pullup)
    if (digitalRead(buttons[i].pin) == LOW) {
      handlePress(i, millis());
    }
  }
}

// Runs a press through to release. `pressedAt` is when the press began: for one
// noticed while awake that is now, and for one that woke us from light sleep it
// is the moment of waking, so time spent bringing the radio back up still
// counts towards the hold threshold.
//
// Blocks until the button comes up, which is what the original code did too --
// it doubles as the debounce.
void handlePress(int index, unsigned long pressedAt) {
  const Button &button = buttons[index];
  const char *holdCmd = holdCommandFor(button.name);

  // No hold behaviour: fire on press, exactly as before.
  if (holdCmd == NULL) {
    sendCmd(button.name);
    while (digitalRead(button.pin) == LOW) {
      lastActivity = millis();
      delay(10);
    }
    Serial.println("Button Released");
    return;
  }

  // A tap and a hold are indistinguishable until the button crosses the
  // threshold or comes back up, so nothing can be sent on press. The hold
  // command goes out the moment the threshold passes -- waiting for release
  // would mean no response at all while the button is down.
  bool holdFired = false;

  while (digitalRead(button.pin) == LOW) {
    if (!holdFired && millis() - pressedAt >= HOLD_THRESHOLD_MS) {
      sendCmd(holdCmd);
      holdFired = true;
    }
    lastActivity = millis();
    delay(10);
  }

  // Released without ever crossing the threshold, so it was a tap.
  if (!holdFired) {
    sendCmd(button.name);
  }
  Serial.println("Button Released");
}

void sendCmd(const char *cmd) {
  RemotePacket packet;
  remotePacketInit(&packet, REMOTE_LOCATION, cmd);

  Serial.printf("Sending: %s [%s]\n", cmd, REMOTE_LOCATION);

  esp_err_t result = esp_now_send(broadcastAddress, (const uint8_t *)&packet,
                                  sizeof(packet));

  if (result == ESP_OK) {
    Serial.println("Sent with success");
  } else {
    Serial.println("Error sending the data");
  }

  lastActivity = millis(); // Reset sleep timer
}

void goToSleep() {
  Serial.println("Going to sleep now");
  Serial.flush(); // Ensure everything is printed before CPU halts

  // Enable Wakeup on ALL buttons
  // Note: For Light Sleep, we can use gpio_wakeup_enable
  esp_sleep_enable_gpio_wakeup();

  for (int i = 0; i < buttonCount; i++) {
    // Use GPIO_INTR_LOW_LEVEL for pressed state (since INPUT_PULLUP)
    gpio_wakeup_enable((gpio_num_t)buttons[i].pin, GPIO_INTR_LOW_LEVEL);
  }

  // Enter Light Sleep
  // The CPU will pause here and resume after wakeup
  esp_light_sleep_start();

  // Resume here after wakeup

  // The button that woke us has been down since this instant. Capture it before
  // anything else so the hold threshold is measured from the press itself and
  // not from whenever the radio finished coming back up.
  const unsigned long wokeAt = millis();

  // 1. CAPTURE: Check which button woke us up immediately
  int pendingIndex = -1;

  Serial.println("Woke up!");

  for (int i = 0; i < buttonCount; i++) {
    if (digitalRead(buttons[i].pin) == LOW) {
      pendingIndex = i;

      break; // Found it
    }
  }

  // FIX: Force channel again after wake
  // We completely re-initialize the stack to ensure clean state
  esp_now_deinit();
  WiFi.mode(WIFI_OFF);
  delay(10);
  setupESPNow();
  delay(100); // Allow radio to stabilize before checking buttons again

  // 2. SEND: Now that the radio is ready, run the press through normally. A
  // button released during the radio restart reads as a tap, which is right --
  // it was one.
  if (pendingIndex >= 0) {
    handlePress(pendingIndex, wokeAt);
  }

  lastActivity = millis(); // Reset timer to avoid immediate sleep loop

  // Disable wakeup sources to avoid spurious triggers or re-configure if needed
  // (Optional, but good practice to clear if we had different needs)
  // For this loop, we just re-enter the main loop.
}
