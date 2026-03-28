import AppKit
import Foundation
import Sparkle

final class DongleBatteryMonitor {
    private enum Timing {
        static let retryDelaySeconds: TimeInterval = 3
    }

    private enum HelperExitCode: Int32 {
        case success = 0
        case timedOut = 2
        case receiverNotFound = 10
        case inputMonitoringRequired = 11
    }

    struct Reading {
        let percent: Int?
        let charging: Bool
        let voltage: Int?
        let stateText: String
    }

    var onUpdate: ((Reading) -> Void)?

    private var task: Process?
    private var lastSuccessfulReading: Reading?
    private var retryWorkItem: DispatchWorkItem?

    private var helperExecutableURL: URL? {
        let helperApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Lofree Dongle Battery Access.app")
        let executable = helperApp.appendingPathComponent("Contents/MacOS/LofreeDongleBatteryAccess")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    func refresh() {
        retryWorkItem?.cancel()
        retryWorkItem = nil

        guard task == nil else {
            return
        }

        guard let helperExecutableURL else {
            publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "Battery access helper missing"))
            return
        }

        let process = Process()
        process.executableURL = helperExecutableURL
        let stdout = Pipe()
        process.standardOutput = stdout

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            self.task = nil

            if let reading = self.parseReading(output) {
                self.lastSuccessfulReading = reading
                self.publish(reading)
            } else {
                self.handleFailedRead(process.terminationStatus)
            }
        }

        do {
            try process.run()
            task = process
            if let lastSuccessfulReading {
                publish(Reading(
                    percent: lastSuccessfulReading.percent,
                    charging: lastSuccessfulReading.charging,
                    voltage: lastSuccessfulReading.voltage,
                    stateText: "Refreshing 2.4 GHz battery…"
                ))
            } else {
                publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "Reading 2.4 GHz battery…"))
            }
        } catch {
            publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "Launch failed"))
        }
    }

    private func parseReading(_ output: String) -> Reading? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BATTERY") else { return nil }

        var percent: Int?
        var charging: Int?
        var voltage: Int?
        for token in trimmed.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "percent":
                percent = Int(parts[1])
            case "charging":
                charging = Int(parts[1])
            case "voltage":
                voltage = Int(parts[1])
            default:
                break
            }
        }

        guard let percent, let charging, let voltage else { return nil }
        let stateText = charging != 0 ? "2.4 GHz charging" : "2.4 GHz connected"
        return Reading(percent: percent, charging: charging != 0, voltage: voltage, stateText: stateText)
    }

    private func publish(_ reading: Reading) {
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(reading)
        }
    }

    private func scheduleRetry() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.retryDelaySeconds, execute: workItem)
    }

    private func handleFailedRead(_ exitCode: Int32) {
        switch HelperExitCode(rawValue: exitCode) {
        case .receiverNotFound:
            publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "2.4 GHz receiver not found"))
        case .inputMonitoringRequired:
            publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "Allow Input Monitoring"))
        case .timedOut:
            if let lastSuccessfulReading {
                publish(Reading(
                    percent: lastSuccessfulReading.percent,
                    charging: lastSuccessfulReading.charging,
                    voltage: lastSuccessfulReading.voltage,
                    stateText: "2.4 GHz retrying…"
                ))
            } else {
                publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "2.4 GHz retrying…"))
            }
            scheduleRetry()
        case .success, .none:
            if let lastSuccessfulReading {
                publish(Reading(
                    percent: lastSuccessfulReading.percent,
                    charging: lastSuccessfulReading.charging,
                    voltage: lastSuccessfulReading.voltage,
                    stateText: "2.4 GHz reconnecting…"
                ))
            } else {
                publish(Reading(percent: nil, charging: false, voltage: nil, stateText: "2.4 GHz reconnecting…"))
            }
            scheduleRetry()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Timing {
        static let steadyRefreshInterval: TimeInterval = 180
    }

    private enum StatusStyle {
        static let font = NSFont.systemFont(ofSize: 11, weight: .regular)
    }

    private enum Support {
        static let menuTitle = "Buy me a coffee"
        static let url = "https://digitaledens.com/buy-me-a-coffee/"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = DongleBatteryMonitor()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var reading = DongleBatteryMonitor.Reading(percent: nil, charging: false, voltage: nil, stateText: "Starting…")
    private var timer: Timer?
    private var hasShownPermissionAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusButton()
        monitor.onUpdate = { [weak self] reading in
            self?.reading = reading
            self?.updateUI()
            self?.maybeShowPermissionAlert()
        }
        updateUI()
        monitor.refresh()

        timer = Timer.scheduledTimer(withTimeInterval: Timing.steadyRefreshInterval, repeats: true) { [weak self] _ in
            self?.monitor.refresh()
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true

        if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Lofree 2.4 GHz battery") {
            image.isTemplate = true
            button.image = image
        }
    }

    private func updateUI() {
        let titleText: String
        if let percent = reading.percent {
            titleText = "\(percent)%"
        } else if reading.stateText == "Allow Input Monitoring" {
            titleText = "!"
        } else {
            titleText = "..."
        }

        statusItem.button?.attributedTitle = NSAttributedString(
            string: titleText,
            attributes: [.font: StatusStyle.font]
        )

        let menu = NSMenu()
        menu.addItem(withTitle: reading.stateText, action: nil, keyEquivalent: "")
        if let percent = reading.percent {
            menu.addItem(withTitle: "Battery: \(percent)%", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Battery: unavailable", action: nil, keyEquivalent: "")
        }
        if let voltage = reading.voltage {
            menu.addItem(withTitle: "Voltage: \(voltage) mV", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Connection: 2.4 GHz only", action: nil, keyEquivalent: "")
        if reading.stateText == "Allow Input Monitoring" {
            menu.addItem(withTitle: "Enable: Lofree Dongle Battery Access", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") {
            image.isTemplate = true
            refreshItem.image = image
        }
        menu.addItem(refreshItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        if let image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Check for Updates") {
            image.isTemplate = true
            updatesItem.image = image
        }
        menu.addItem(updatesItem)
        menu.addItem(.separator())

        if reading.stateText == "Allow Input Monitoring" {
            let settingsItem = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringFromMenu), keyEquivalent: "")
            settingsItem.target = self
            if let image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Open Input Monitoring Settings") {
                image.isTemplate = true
                settingsItem.image = image
            }
            menu.addItem(settingsItem)
        }

        let supportItem = NSMenuItem(title: Support.menuTitle, action: #selector(openSupportLink), keyEquivalent: "")
        supportItem.target = self
        if let image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: Support.menuTitle) {
            image.isTemplate = true
            supportItem.image = image
        }
        menu.addItem(supportItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func maybeShowPermissionAlert() {
        guard reading.stateText == "Allow Input Monitoring" else { return }
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.openInputMonitoringSettings()

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Allow Input Monitoring"
            alert.informativeText = """
            This permission is required because macOS protects direct access to keyboard-like USB receivers behind Input Monitoring.

            Without this permission, the app cannot read the battery over 2.4 GHz and the percentage will not appear.

            In this app, it is used only to ask the Lofree dongle for battery data. It does not capture, store, or send your keystrokes.

            To read the keyboard battery over 2.4 GHz, enable Input Monitoring for:

            Lofree Dongle Battery Access

            If it is not already listed, wait a moment for macOS to add it automatically after the helper tries to access the receiver, then enable it in:

            System Settings > Privacy & Security > Input Monitoring
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.openInputMonitoringSettings()
            }
        }
    }

    private func openInputMonitoringSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security",
        ]

        for rawURL in urls {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func refreshNow() {
        monitor.refresh()
    }

    @objc private func checkForUpdates() {
        clearUpdateFeedCache()
        updaterController.checkForUpdates(self)
    }

    private func clearUpdateFeedCache() {
        guard let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feedURLString) else {
            URLCache.shared.removeAllCachedResponses()
            return
        }

        URLCache.shared.removeCachedResponse(for: URLRequest(url: feedURL))
        URLCache.shared.removeAllCachedResponses()
    }

    @objc private func openInputMonitoringFromMenu() {
        openInputMonitoringSettings()
    }

    @objc private func openSupportLink() {
        guard let url = URL(string: Support.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
