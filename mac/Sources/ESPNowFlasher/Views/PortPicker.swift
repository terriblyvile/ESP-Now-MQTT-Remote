import FlasherCore
import SwiftUI

/// Detected ports by default, with typing a path as the escape hatch.
///
/// Detection is right for the common case — one board on USB — and the free-text
/// field is there for a port the machine has but cannot enumerate.
struct PortPicker: View {
    @Bindable var model: AppModel
    let slot: PortSlot

    private var choice: Binding<PortChoice> {
        Binding(
            get: { model.portChoices[slot] ?? PortChoice() },
            set: { model.portChoices[slot] = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if choice.wrappedValue.isManual {
                TextField("/dev/cu.usbserial-0001", text: choice.device)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 280)
            } else {
                Picker("", selection: choice.device) {
                    if model.ports.isEmpty {
                        Text("no serial ports found").tag("")
                    }
                    ForEach(model.ports) { port in
                        Text(port.label).tag(port.device)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
            }

            Button(choice.wrappedValue.isManual ? "Pick Detected" : "Type a Path") {
                toggle()
            }
            .controlSize(.small)
        }
    }

    private func toggle() {
        var next = choice.wrappedValue
        next.isManual.toggle()
        if !next.isManual, !model.ports.contains(where: { $0.device == next.device }) {
            // Coming back from a hand-typed path that is not in the list; drop
            // to the first real port rather than showing a selection that is not
            // among the options.
            next.device = model.ports.first?.device ?? ""
        }
        // Going the other way the current choice is carried over deliberately,
        // so it can be edited rather than retyped.
        choice.wrappedValue = next
    }
}
