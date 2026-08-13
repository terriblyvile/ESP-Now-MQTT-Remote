import FlasherCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case overview, credentials, radio, remotes, hubs, flash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .credentials: "Credentials"
        case .radio: "Radio & Topics"
        case .remotes: "Define Remotes"
        case .hubs: "Flash a Base Station"
        case .flash: "Flash a Remote"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            "Flash a hub, read its ESP-NOW address off the boot log, then flash remotes that talk to it."
        case .credentials: "WiFi, MQTT broker and OTA passwords."
        case .radio: "Channel, MQTT topic root and hold threshold."
        case .remotes: "One row per physical handset."
        case .hubs: "Upload to a hub, then capture the address remotes transmit to."
        case .flash: "Build a handset's firmware and upload it over USB."
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .credentials: "key"
        case .radio: "antenna.radiowaves.left.and.right"
        case .remotes: "list.bullet"
        case .hubs: "server.rack"
        case .flash: "bolt"
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    /// A list's selection is optional, because clicking away deselects. The
    /// model's is not -- something is always showing -- so an empty selection
    /// is treated as "leave it where it is".
    private var selection: Binding<Page?> {
        Binding(
            get: { model.page },
            set: { if let new = $0 { model.page = new } }
        )
    }

    var body: some View {
        Group {
            if model.root == nil {
                WelcomeView(model: model)
            } else {
                workspace
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var workspace: some View {
        NavigationSplitView {
            // Tagged by hand. `List(Page.allCases, selection:)` looks equivalent
            // but tags each row with the element's *id* -- a String here --
            // while the binding is a Page, so nothing a click produces can ever
            // match it. It compiles, and the sidebar silently does nothing.
            List(selection: selection) {
                ForEach(Page.allCases) { entry in
                    Label(entry.title, systemImage: entry.symbol)
                        .tag(entry)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                LogPane(model: model)
            }
            .toolbar { toolbar }
        }
        // Boards come and go on USB; keep the pickers honest without a refresh.
        // Paused while a job runs, so nothing moves under a flash in progress.
        .task {
            while !Task.isCancelled {
                if !model.isBusy { model.refreshPorts() }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .overview: DashboardView(model: model)
        case .credentials: CredentialsView(model: model)
        case .radio: RadioView(model: model)
        case .remotes: RemotesView(model: model)
        case .hubs: HubsView(model: model)
        case .flash: FlashRemoteView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let root = model.root {
                Button {
                    model.chooseProject()
                } label: {
                    Label(root.lastPathComponent, systemImage: "folder")
                }
                .help(root.path)
            }
        }
        ToolbarItem {
            if model.hasUnsavedChanges {
                Label("Unsaved changes", systemImage: "pencil.circle")
                    .foregroundStyle(.orange)
                    .help("The generated files on disk do not match what is on screen.")
            }
        }
    }
}

/// Shown until a firmware checkout has been chosen.
///
/// The Python flasher was run from inside the repository and so always knew
/// where it was. An app has to be told once.
struct WelcomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("ESP-NOW Remote Flasher")
                .font(.title2.weight(.semibold))

            Text("Choose your firmware checkout — the folder holding "
                 + "**platformio.ini** and **include/config.h**.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Choose Project Folder…") { model.chooseProject() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

            if let status = model.configStatus {
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(status.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Link("Get the firmware on GitHub", destination: repositoryURL)
                .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - shared chrome

/// Title, subtitle and a scrolling body, so every page is laid out the same way.
struct PageScaffold<Content: View>: View {
    @Bindable var model: AppModel
    let page: Page
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The sidebar is the other way back, but a tile press is a
                // one-way trip into a page, and the way out should be where you
                // are looking rather than somewhere else on screen.
                if page != .overview {
                    Button {
                        model.page = .overview
                    } label: {
                        Label("Overview", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title).font(.title2.weight(.semibold))
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A bordered group with an explanation above it, matching the web tool's
/// "hint then controls" rhythm.
struct Card<Content: View>: View {
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hint {
                Text(.init(hint))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StatusLabel: View {
    let status: StatusMessage?

    var body: some View {
        if let status {
            HStack(spacing: 6) {
                if status.kind == .busy {
                    ProgressView().controlSize(.small)
                }
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
