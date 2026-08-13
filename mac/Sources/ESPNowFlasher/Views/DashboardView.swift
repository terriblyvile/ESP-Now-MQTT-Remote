import FlasherCore
import SwiftUI

/// The tiles double as a status board, so the page is worth coming back to.
struct DashboardView: View {
    @Bindable var model: AppModel

    private struct Tile: Identifiable {
        let page: Page
        let blurb: String
        let status: String
        let ready: Bool
        var id: String { page.id }
    }

    private var tiles: [Tile] {
        let macs = HubKind.allCases.filter { !model.state.mac(for: $0).trimmed.isEmpty }
        let readyRemotes = model.state.remotes.filter { model.blockedReason(for: $0) == nil }.count
        let remoteCount = model.state.remotes.count

        return [
            Tile(
                page: .credentials,
                blurb: "WiFi, MQTT broker and OTA passwords",
                status: model.secrets.isComplete
                    ? "\(model.secrets.wifiSSID) · \(model.secrets.mqttHost)"
                    : "not set yet",
                ready: model.secrets.isComplete
            ),
            Tile(
                page: .radio,
                blurb: "Channel, MQTT topic root, hold threshold",
                status: "channel \(model.state.wifiChannel) · \(model.state.topicRoot)/",
                ready: true
            ),
            Tile(
                page: .remotes,
                blurb: "Add, name and assign each handset",
                status: remoteCount == 1 ? "1 remote" : "\(remoteCount) remotes",
                ready: remoteCount > 0
            ),
            Tile(
                page: .hubs,
                blurb: "Upload to a hub and capture its address",
                status: macs.count == 2 ? "both addresses captured"
                    : macs.count == 1 ? "\(macs[0].rawValue) address captured"
                    : "no address captured",
                ready: !macs.isEmpty
            ),
            Tile(
                page: .flash,
                blurb: "Build and upload to a handset",
                status: readyRemotes > 0
                    ? "\(readyRemotes) ready to flash"
                    : "capture a hub address first",
                ready: readyRemotes > 0
            ),
        ]
    }

    var body: some View {
        PageScaffold(model: model, page: .overview) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 215), spacing: 14)],
                spacing: 14
            ) {
                ForEach(tiles) { tile in
                    Button {
                        model.page = tile.page
                    } label: {
                        TileBody(
                            symbol: tile.page.symbol,
                            title: tile.page.title,
                            blurb: tile.blurb,
                            status: tile.status,
                            ready: tile.ready
                        )
                    }
                    .buttonStyle(.plain)
                    // A plain button wrapping a fully custom label takes focus
                    // but is not activated by the keyboard on its own, which
                    // leaves the focus ring sitting on something that ignores
                    // Return. Wire both keys up explicitly.
                    .onKeyPress(.return) { model.page = tile.page; return .handled }
                    .onKeyPress(.space) { model.page = tile.page; return .handled }
                }

                Link(destination: repositoryURL) {
                    TileBody(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        title: "GitHub Repository",
                        blurb: "Source, firmware and documentation",
                        status: "opens in your browser",
                        ready: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TileBody: View {
    let symbol: String
    let title: String
    let blurb: String
    let status: String
    /// nil where "ready" means nothing, as on the repository link.
    let ready: Bool?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)

            Text(title).font(.headline)

            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(status)
                .font(.caption)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(statusColor.opacity(0.5)))
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
        )
        .onHover { hovering = $0 }
    }

    private var statusColor: Color {
        switch ready {
        case .some(true): .green
        case .some(false): .orange
        case nil: .secondary
        }
    }
}
