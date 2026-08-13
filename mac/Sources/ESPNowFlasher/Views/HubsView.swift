import FlasherCore
import SwiftUI

struct HubsView: View {
    @Bindable var model: AppModel

    @State private var otaHub: HubKind?
    @State private var otaHost = ""

    var body: some View {
        PageScaffold(model: model, page: .hubs) {
            Card(hint: "Flash a hub, then capture its address. Remotes unicast to one hub's "
                 + "MAC, so a press reaches exactly one of them — both hubs can run at "
                 + "once. You only need the hub you actually own.") {
                EmptyView()
            }

            ForEach(HubKind.allCases) { hub in
                HubCard(model: model, hub: hub) {
                    otaHost = hub.otaHostname
                    otaHub = hub
                }
            }

            PortHint(model: model)

            Card(hint: "Over-the-air uploads use the hostname the hub advertises "
                 + "(`esp_hub_wifi.local` / `esp_hub_eth.local`) and the OTA password. "
                 + "A hub has to be running working firmware already.") {
                SaveConfigBar(model: model)
            }
        }
        .alert(
            "Reflash Over the Air",
            isPresented: Binding(
                get: { otaHub != nil },
                set: { if !$0 { otaHub = nil } }
            )
        ) {
            TextField("Hostname or IP", text: $otaHost)
            Button("Cancel", role: .cancel) { otaHub = nil }
            Button("Upload") {
                if let hub = otaHub {
                    model.flashHubOverTheAir(hub, host: otaHost)
                }
                otaHub = nil
            }
        } message: {
            Text("Hostname or IP of the hub to reflash.")
        }
    }
}

private struct HubCard: View {
    @Bindable var model: AppModel
    let hub: HubKind
    let startOTA: () -> Void

    private var mac: String { model.state.mac(for: hub) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(hub.label).font(.headline)
                    Text(mac.trimmed.isEmpty ? "no address yet" : mac.uppercased())
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(badgeColor.opacity(0.5)))
                        .foregroundStyle(badgeColor)
                }

                Text("\(hub.boardDescription). Build target `\(hub.environment)`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("ESP-NOW address")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        TextField("not captured yet", text: Binding(
                            get: { model.state.mac(for: hub) },
                            set: { model.state.setMac($0, for: hub) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 220)
                    }
                    GridRow {
                        Text("Serial port")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        PortPicker(model: model, slot: PortSlot(hub: hub))
                    }
                }

                HStack(spacing: 10) {
                    Button("Flash over USB") { model.flashHub(hub) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    Button("Capture Address") { model.captureAddress(for: hub) }
                        .disabled(model.isBusy)
                    Button("Reflash Over the Air", action: startOTA)
                        .disabled(model.isBusy)
                }

                if hub == .wired {
                    WiredHubGuide()
                }
            }
        }
    }

    private var badgeColor: Color {
        mac.trimmed.isEmpty ? .orange : .green
    }
}

/// The WT32-ETH01 has no USB and no auto-reset, so two of its steps are manual
/// and there is no way to infer that from the UI alone.
private struct WiredHubGuide: View {
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Wire a **3.3V** USB-to-serial adapter: `TX→RX0`, `RX→TX0`, `GND`, `3V3`.")
                step(2, "Tie `GPIO 0` to `GND`, then power the board up. It is now in download mode.")
                step(3, "Press **Flash over USB** above and wait for it to finish.")
                step(4, "Remove the `GPIO 0` jumper and power-cycle the board so it runs the firmware.")
                step(5, "Press **Capture Address**, then power-cycle once more so it reprints its boot banner.")

                Text("There is no auto-reset on this board, because `GPIO 0` is also the "
                     + "PHY clock input. That is why steps 4 and 5 are manual, and why "
                     + "capture here listens rather than pulsing reset.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.top, 8)
        } label: {
            Text("This board has no USB — wiring and download mode")
                .font(.callout)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown when nothing is plugged in, because "no serial ports found" on a Mac
/// has a much shorter list of causes than it did in a container.
struct PortHint: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.ports.isEmpty {
            Label(
                "No serial ports found. Plug the board in over USB and check the cable "
                + "carries data — charge-only cables enumerate nothing. Boards using a "
                + "CH340 or CP210x need that vendor's driver installed. If you know the "
                + "path but it is not being detected, use Type a Path.",
                systemImage: "cable.connector"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
