import FlasherCore
import SwiftUI

/// Where the source lives, shown on the dashboard and in the Help menu.
let repositoryURL = URL(string: "https://github.com/terriblyvile/ESP-Now-MQTT-Remote")!

@main
struct FlasherApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("ESP-NOW Remote Flasher", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1000, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open Project…") { model.chooseProject() }
                    .keyboardShortcut("o")
                Button("Reload from Disk") { model.reload() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Log", isOn: Binding(
                    get: { model.isLogVisible },
                    set: { model.isLogVisible = $0 }
                ))
                .keyboardShortcut("l")
            }
            CommandGroup(replacing: .help) {
                Link("ESP-NOW MQTT Remote on GitHub", destination: repositoryURL)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
