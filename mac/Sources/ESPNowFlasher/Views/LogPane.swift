import FlasherCore
import SwiftUI

/// Build and capture output, streamed as it arrives.
///
/// Pinned to the bottom of the window rather than opened in a sheet: a failed
/// upload is read while changing something else, and a modal would hide the
/// thing being changed.
struct LogPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            bar
            if model.isLogVisible {
                Divider()
                lines.frame(height: 260)
            }
        }
        .background(.bar)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(model.jobLabel)
                .font(.callout)
                .foregroundStyle(model.isBusy ? .primary : .secondary)
                .lineLimit(1)

            Spacer()

            Button("Stop") { model.cancel() }
                .disabled(!model.isBusy)
            Button("Clear") { model.clearLog() }
                .disabled(model.log.isEmpty)
            Button(model.isLogVisible ? "Hide Log" : "Show Log") {
                model.isLogVisible.toggle()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.kind.color ?? .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log.count) {
                guard let last = model.log.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var platformIOPath = PlatformIO.overridePath ?? ""

    private var detected: String {
        (try? PlatformIO.find()) ?? "not found"
    }

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.root?.path ?? "none chosen")
                            .foregroundStyle(.secondary)
                            .truncationMode(.head)
                            .lineLimit(1)
                        Button("Change…") { model.chooseProject() }
                    }
                }
            }

            Section("PlatformIO") {
                LabeledContent("In use") {
                    Text(detected)
                        .foregroundStyle(.secondary)
                        .truncationMode(.head)
                        .lineLimit(1)
                }
                LabeledContent("Override path") {
                    HStack {
                        TextField("", text: $platformIOPath, prompt: Text("auto-detect"))
                            .textFieldStyle(.roundedBorder)
                        Button("Apply") {
                            PlatformIO.overridePath = platformIOPath.trimmed
                        }
                    }
                }
                Text("An app launched from Finder inherits almost no PATH, so the "
                     + "usual install locations are searched directly and your login "
                     + "shell is asked as a fallback. Set this only if that guesses wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}
