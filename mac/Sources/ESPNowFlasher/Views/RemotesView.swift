import FlasherCore
import SwiftUI

struct RemotesView: View {
    @Bindable var model: AppModel

    var body: some View {
        PageScaffold(model: model, page: .remotes) {
            Card(hint: "Each becomes a Home Assistant device and an MQTT topic branch. The "
                 + "location is used verbatim in the topic, so it is lowercase and "
                 + "underscore-only, and at most \(ConfigStore.maxLocationLength) characters.") {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ForEach($model.state.remotes) { $remote in
                        RemoteRow(remote: $remote) {
                            model.state.remotes.removeAll { $0.id == remote.id }
                        }
                        Divider()
                    }
                }
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                if model.state.remotes.isEmpty {
                    Text("No remotes yet. Add one to generate its build environment.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.addRemote()
                } label: {
                    Label("Add Remote", systemImage: "plus")
                }

                SaveConfigBar(model: model)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Location").frame(width: 150, alignment: .leading)
            Text("Display name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Talks to").frame(width: 130, alignment: .leading)
            Spacer().frame(width: 24)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct RemoteRow: View {
    @Binding var remote: Remote
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("livingroom", text: $remote.location)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            TextField("Living Room Remote", text: $remote.name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Picker("", selection: $remote.hub) {
                ForEach(HubKind.allCases) { hub in
                    Text(hub.label).tag(hub)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button(role: .destructive) {
                delete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this remote")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct FlashRemoteView: View {
    @Bindable var model: AppModel

    private var selected: Remote? {
        model.state.remotes.first { $0.id == model.selectedRemoteID }
            ?? model.state.remotes.first
    }

    var body: some View {
        PageScaffold(model: model, page: .flash) {
            Card(hint: "A remote must be reflashed whenever its hub's address changes. "
                 + "Unsaved configuration is written out before the build starts, so what "
                 + "you see here is what gets compiled in.") {
                if model.state.remotes.isEmpty {
                    Text("No remotes configured yet — add one under Define Remotes.")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text("Remote")
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $model.selectedRemoteID) {
                                ForEach(model.state.remotes) { remote in
                                    Text(label(for: remote))
                                        .tag(Optional(remote.id))
                                }
                            }
                            .labelsHidden()
                        }
                        GridRow {
                            Text("Serial port")
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            PortPicker(model: model, slot: .remote)
                        }
                    }

                    if let selected, let reason = model.blockedReason(for: selected) {
                        Label(
                            "\(selected.location) \(reason). Flash that hub and capture its "
                            + "address first, or this remote transmits into nothing.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button("Flash over USB") {
                            if let selected { model.flashRemote(selected) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isBusy
                            || selected == nil
                            || model.blockedReason(for: selected!) != nil
                        )
                    }
                    .padding(.top, 4)
                }
            }

            PortHint(model: model)
        }
    }

    private func label(for remote: Remote) -> String {
        let name = remote.name.trimmed.isEmpty ? remote.location : remote.name
        if let reason = model.blockedReason(for: remote) {
            return "\(name) — \(remote.environment) (\(reason))"
        }
        return "\(name) — \(remote.environment)"
    }
}
