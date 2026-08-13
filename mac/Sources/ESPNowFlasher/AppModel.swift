import AppKit
import FlasherCore
import Foundation
import SwiftUI

/// One line in the log pane.
struct LogLine: Identifiable {
    enum Kind {
        case plain, command, error, good, note

        var color: Color? {
            switch self {
            case .plain: nil
            case .command: .cyan
            case .error: .red
            case .good: .green
            case .note: .orange
            }
        }
    }

    let id = UUID()
    let text: String
    let kind: Kind

    /// Colouring the log by pattern rather than by source: PlatformIO's own
    /// output is the bulk of it, and its failures are worth spotting without
    /// reading every line.
    init(_ text: String) {
        self.text = text
        if text.hasPrefix("$ ") {
            kind = .command
        } else if text.range(of: "\\berror\\b|\\bfailed\\b|FAILED|Traceback",
                             options: [.regularExpression, .caseInsensitive]) != nil {
            kind = .error
        } else if text.contains("SUCCESS") || text.contains("[flasher] captured") {
            kind = .good
        } else if text.hasPrefix("[flasher]") {
            kind = .note
        } else {
            kind = .plain
        }
    }
}

struct StatusMessage: Equatable {
    enum Kind { case ok, bad, busy }
    var text: String
    var kind: Kind

    var color: Color {
        switch kind {
        case .ok: .green
        case .bad: .red
        case .busy: .secondary
        }
    }
}

/// Which serial picker a selection belongs to.
enum PortSlot: String, CaseIterable {
    case wired, wireless, remote

    init(hub: HubKind) {
        self = hub == .wired ? .wired : .wireless
    }
}

struct PortChoice: Equatable {
    var device = ""
    /// Escape hatch for a port the machine has but cannot enumerate.
    var isManual = false
}

/// Lets a blocking capture on a background thread notice a Stop press.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: - navigation

    /// Which section is showing. Held here rather than in a view's `@State` so
    /// the sidebar, the dashboard tiles and the back button are all driving one
    /// value instead of three that have to be kept in step.
    var page: Page = .overview

    // MARK: - project

    private(set) var store: ConfigStore?
    var root: URL? { store?.root }

    // MARK: - configuration

    var state = FlasherState()
    var secrets = Secrets()
    /// What is actually on disk, so unsaved edits can be pointed out rather than
    /// silently ignored by the next build.
    private var savedState = FlasherState()

    var hasUnsavedChanges: Bool { state != savedState }

    // MARK: - devices

    private(set) var ports: [SerialPort] = []
    var portChoices: [PortSlot: PortChoice] = [:]
    var selectedRemoteID: Remote.ID?

    // MARK: - jobs

    private(set) var log: [LogLine] = []
    private(set) var isBusy = false
    private(set) var jobLabel = "Idle"
    var isLogVisible = false

    private var runner: CommandRunner?
    private var captureFlag: CancelFlag?

    /// A full build runs into the thousands of lines and the interesting part is
    /// always the end; keeping every line of every job just costs memory.
    private static let logLimit = 5_000

    var secretsStatus: StatusMessage?
    var configStatus: StatusMessage?

    // MARK: - lifecycle

    init() {
        if let discovered = ProjectRoot.discover() {
            open(discovered)
        }
    }

    func open(_ url: URL) {
        guard ProjectRoot.isProject(url) else {
            configStatus = StatusMessage(
                text: "\(url.lastPathComponent) is not the firmware project — "
                    + "it has no platformio.ini and include/config.h.",
                kind: .bad
            )
            return
        }
        ProjectRoot.remember(url)
        let store = ConfigStore(root: url)
        self.store = store
        configStatus = nil
        reload()
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project"
        panel.message = "Choose the firmware checkout — the folder holding platformio.ini."
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func reload() {
        guard let store else { return }
        do {
            state = try store.loadState()
            savedState = state
            secrets = try store.loadSecrets()
            if selectedRemoteID == nil { selectedRemoteID = state.remotes.first?.id }
        } catch {
            append("[flasher] could not read the project: \(error.localizedDescription)")
        }
        refreshPorts()
    }

    // MARK: - ports

    func refreshPorts() {
        ports = SerialPorts.list()
        for slot in PortSlot.allCases {
            var choice = portChoices[slot] ?? PortChoice()
            let stillThere = ports.contains { $0.device == choice.device }
            // Only ever moved when the current pick has gone away, so the list
            // refreshing under you cannot change what you are about to flash.
            if !choice.isManual, !stillThere {
                choice.device = ports.first?.device ?? ""
            }
            portChoices[slot] = choice
        }
    }

    func port(for slot: PortSlot) -> String {
        (portChoices[slot] ?? PortChoice()).device.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - saving

    func saveSecrets() {
        guard let store else { return }
        secretsStatus = StatusMessage(text: "saving…", kind: .busy)
        do {
            try store.writeSecrets(secrets)
            secretsStatus = StatusMessage(text: "written to include/secrets.h", kind: .ok)
        } catch {
            secretsStatus = StatusMessage(text: error.localizedDescription, kind: .bad)
        }
    }

    @discardableResult
    func saveConfig() -> Bool {
        guard let store else { return false }
        configStatus = StatusMessage(text: "saving…", kind: .busy)
        do {
            try store.apply(state)
            savedState = state
            configStatus = StatusMessage(
                text: "device_config.h and platformio_local.ini written", kind: .ok
            )
            return true
        } catch {
            configStatus = StatusMessage(text: error.localizedDescription, kind: .bad)
            return false
        }
    }

    func addRemote() {
        state.remotes.append(Remote(location: "", name: "", hub: .wired))
        selectedRemoteID = state.remotes.last?.id
    }

    func deleteRemotes(at offsets: IndexSet) {
        state.remotes.remove(atOffsets: offsets)
        if let selectedRemoteID, !state.remotes.contains(where: { $0.id == selectedRemoteID }) {
            self.selectedRemoteID = state.remotes.first?.id
        }
    }

    // MARK: - flashing

    /// Remotes that can be built right now, with the reason when they cannot.
    func blockedReason(for remote: Remote) -> String? {
        guard state.mac(for: remote.hub).trimmed.isEmpty else { return nil }
        return "needs the \(remote.hub.rawValue) hub's address"
    }

    func flashHub(_ hub: HubKind) {
        let port = port(for: PortSlot(hub: hub))
        guard !port.isEmpty else { return complain("no serial port selected") }
        run(environment: hub.environment, uploadPort: port, label: "\(hub.environment) → \(port)")
    }

    func flashHubOverTheAir(_ hub: HubKind, host: String) {
        let target = host.trimmed
        guard !target.isEmpty else { return complain("no hostname given") }
        run(environment: hub.otaEnvironment, uploadPort: target,
            label: "\(hub.otaEnvironment) → \(target)")
    }

    func flashRemote(_ remote: Remote) {
        let port = port(for: .remote)
        guard !port.isEmpty else { return complain("no serial port selected") }
        if let reason = blockedReason(for: remote) {
            return complain(
                "\(remote.location) \(reason). Flash that hub and capture its address "
                + "first, or this remote transmits into nothing."
            )
        }
        run(environment: remote.environment, uploadPort: port,
            label: "\(remote.environment) → \(port)")
    }

    private func run(environment: String, uploadPort: String, label: String) {
        guard !isBusy, let store else { return }

        // The build reads the generated files, so unsaved edits would silently
        // produce firmware for the previous configuration. Saving first is what
        // pressing flash actually means.
        if hasUnsavedChanges {
            guard saveConfig() else {
                return complain(
                    "the configuration has unsaved changes that cannot be written: "
                    + (configStatus?.text ?? "invalid")
                )
            }
            append("[flasher] saved the configuration before building")
        }

        let executable: String
        do {
            executable = try PlatformIO.find()
        } catch {
            return complain(error.localizedDescription)
        }

        let arguments = PlatformIO.arguments(
            environment: environment, upload: true, uploadPort: uploadPort
        )
        let runner = CommandRunner(
            executable: executable,
            arguments: arguments,
            directory: store.root,
            environment: PlatformIO.environment()
        )
        self.runner = runner

        begin(label)
        append("$ \(executable) \(arguments.joined(separator: " "))")
        do {
            try runner.start(
                onLine: { line in Task { @MainActor in self.append(line) } },
                onExit: { code in Task { @MainActor in self.finish(code) } }
            )
        } catch {
            append("[flasher] \(error.localizedDescription)")
            finish(-1)
        }
    }

    // MARK: - capture

    func captureAddress(for hub: HubKind) {
        guard !isBusy else { return }
        let port = port(for: PortSlot(hub: hub))
        guard !port.isEmpty else { return complain("no serial port selected") }

        let flag = CancelFlag()
        captureFlag = flag
        begin("capture on \(port)")

        let pulseReset = hub.supportsAutoReset
        Task.detached {
            do {
                let mac = try SerialCapture.capture(
                    port: port,
                    timeout: 30,
                    pulseReset: pulseReset,
                    isCancelled: { flag.isCancelled },
                    onLine: { line in Task { @MainActor in self.append(line) } }
                )
                await MainActor.run {
                    self.state.setMac(mac, for: hub)
                    self.append("[flasher] captured \(mac)")
                    self.configStatus = StatusMessage(
                        text: "captured \(mac) — save the configuration to use it", kind: .ok
                    )
                    self.finish(0)
                }
            } catch {
                await MainActor.run {
                    self.append("[flasher] \(error.localizedDescription)")
                    self.finish(1)
                }
            }
        }
    }

    // MARK: - job bookkeeping

    func cancel() {
        runner?.cancel()
        captureFlag?.cancel()
    }

    private func begin(_ label: String) {
        isBusy = true
        jobLabel = label
        isLogVisible = true
    }

    private func finish(_ code: Int32) {
        isBusy = false
        runner = nil
        captureFlag = nil
        jobLabel = code == 0 ? "\(jobLabel) — done" : "\(jobLabel) — failed"
    }

    private func complain(_ message: String) {
        isLogVisible = true
        append("[flasher] \(message)")
    }

    func append(_ text: String) {
        log.append(LogLine(text))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    func clearLog() {
        log.removeAll()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
