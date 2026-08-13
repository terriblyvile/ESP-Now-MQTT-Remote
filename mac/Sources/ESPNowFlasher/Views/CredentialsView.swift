import FlasherCore
import SwiftUI

struct CredentialsView: View {
    @Bindable var model: AppModel

    var body: some View {
        PageScaffold(model: model, page: .credentials) {
            Card(hint: "Written to `include/secrets.h`, which is gitignored. Only the hubs "
                 + "use these — a remote never joins WiFi.") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(SecretField.allCases) { field in
                        GridRow {
                            Text(field.label)
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            field_input(field)
                        }
                        if let help = field.help {
                            GridRow {
                                Color.clear.frame(height: 0)
                                Text(help)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Save Credentials") { model.saveSecrets() }
                        .buttonStyle(.borderedProminent)
                    StatusLabel(status: model.secretsStatus)
                }
                .padding(.top, 4)
            }
        }
    }

    /// Passwords go behind dots. They are still written in clear to a local
    /// header — that is what the firmware build needs — so this hides them from
    /// the room, not from the disk.
    @ViewBuilder
    private func field_input(_ field: SecretField) -> some View {
        let binding = Binding(
            get: { model.secrets[field] },
            set: { model.secrets[field] = $0 }
        )
        if field.isPassword {
            SecureField(field.placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        } else {
            TextField(field.placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct RadioView: View {
    @Bindable var model: AppModel

    var body: some View {
        PageScaffold(model: model, page: .radio) {
            Card(hint: "The channel is the single most common reason a remote does nothing: "
                 + "ESP-NOW has no channel of its own, so this must match the channel your "
                 + "access point runs on. An Ethernet hub never associates and pins the "
                 + "radio here instead.") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("WiFi channel")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField(
                                "", value: $model.state.wifiChannel,
                                format: .number.grouping(.never)
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            Stepper("", value: $model.state.wifiChannel, in: 1...13)
                                .labelsHidden()
                            Text("1–13").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    GridRow {
                        Text("MQTT topic root")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("home", text: $model.state.topicRoot)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Text("\(model.state.topicRoot)/livingroom/remote/command")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    GridRow {
                        Text("Hold threshold")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField(
                                "", value: $model.state.holdThresholdMs,
                                format: .number.grouping(.never)
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            Text("ms before a press counts as held")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                SaveConfigBar(model: model)
            }
        }
    }
}

/// The same save control and message wherever configuration is edited.
struct SaveConfigBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button("Save Configuration") { model.saveConfig() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasUnsavedChanges)
            StatusLabel(status: model.configStatus)
        }
        .padding(.top, 4)
    }
}
