import AppKit
import CoreBluetooth
import Foundation
import Sparkle

struct BatteryReading {
    let percent: Int?
    let charging: Bool
    let voltage: Int?
    let stateText: String
    let connectionText: String
    let requiresInputMonitoring: Bool
    let updatedAt: Date
}

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

    var onUpdate: ((BatteryReading) -> Void)?

    private var task: Process?
    private var lastSuccessfulReading: BatteryReading?
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

        guard task == nil else { return }

        guard let helperExecutableURL else {
            publish(BatteryReading(
                percent: nil,
                charging: false,
                voltage: nil,
                stateText: "Battery access helper missing",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
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
                publish(BatteryReading(
                    percent: lastSuccessfulReading.percent,
                    charging: lastSuccessfulReading.charging,
                    voltage: lastSuccessfulReading.voltage,
                    stateText: "Refreshing 2.4 GHz battery…",
                    connectionText: "2.4 GHz",
                    requiresInputMonitoring: false,
                    updatedAt: Date()
                ))
            } else {
                publish(BatteryReading(
                    percent: nil,
                    charging: false,
                    voltage: nil,
                    stateText: "Reading 2.4 GHz battery…",
                    connectionText: "2.4 GHz",
                    requiresInputMonitoring: false,
                    updatedAt: Date()
                ))
            }
        } catch {
            publish(BatteryReading(
                percent: nil,
                charging: false,
                voltage: nil,
                stateText: "2.4 GHz launch failed",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
        }
    }

    private func parseReading(_ output: String) -> BatteryReading? {
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
        return BatteryReading(
            percent: percent,
            charging: charging != 0,
            voltage: voltage,
            stateText: charging != 0 ? "2.4 GHz charging" : "2.4 GHz connected",
            connectionText: "2.4 GHz",
            requiresInputMonitoring: false,
            updatedAt: Date()
        )
    }

    private func publish(_ reading: BatteryReading) {
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
            publish(BatteryReading(
                percent: nil,
                charging: false,
                voltage: nil,
                stateText: "2.4 GHz receiver not found",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
        case .inputMonitoringRequired:
            publish(BatteryReading(
                percent: nil,
                charging: false,
                voltage: nil,
                stateText: "Allow Input Monitoring",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: true,
                updatedAt: Date()
            ))
        case .timedOut:
            publish(BatteryReading(
                percent: lastSuccessfulReading?.percent,
                charging: lastSuccessfulReading?.charging ?? false,
                voltage: lastSuccessfulReading?.voltage,
                stateText: "2.4 GHz retrying…",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
            scheduleRetry()
        case .success, .none:
            publish(BatteryReading(
                percent: lastSuccessfulReading?.percent,
                charging: lastSuccessfulReading?.charging ?? false,
                voltage: lastSuccessfulReading?.voltage,
                stateText: "2.4 GHz reconnecting…",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
            scheduleRetry()
        }
    }
}

final class BluetoothBatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onUpdate: ((BatteryReading) -> Void)?

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var batteryCharacteristic: CBCharacteristic?
    private var lastSuccessfulReading: BatteryReading?

    func start() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        } else {
            refresh()
        }
    }

    func refresh() {
        guard let centralManager else {
            start()
            return
        }

        guard centralManager.state == .poweredOn else {
            publish(BatteryReading(
                percent: nil,
                charging: false,
                voltage: nil,
                stateText: bluetoothUnavailableText(for: centralManager.state),
                connectionText: "Bluetooth",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
            return
        }

        if let peripheral, let batteryCharacteristic {
            if let lastSuccessfulReading {
                publish(BatteryReading(
                    percent: lastSuccessfulReading.percent,
                    charging: false,
                    voltage: nil,
                    stateText: "Refreshing Bluetooth battery…",
                    connectionText: "Bluetooth",
                    requiresInputMonitoring: false,
                    updatedAt: Date()
                ))
            } else {
                publish(BatteryReading(
                    percent: nil,
                    charging: false,
                    voltage: nil,
                    stateText: "Reading Bluetooth battery…",
                    connectionText: "Bluetooth",
                    requiresInputMonitoring: false,
                    updatedAt: Date()
                ))
            }
            peripheral.readValue(for: batteryCharacteristic)
            return
        }

        discoverKeyboard(using: centralManager)
    }

    private func discoverKeyboard(using centralManager: CBCentralManager) {
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        if let matched = connected.first(where: isLikelyLofreePeripheral) ?? connected.first {
            adopt(peripheral: matched, using: centralManager)
            return
        }

        self.peripheral = nil
        self.batteryCharacteristic = nil
        publish(BatteryReading(
            percent: lastSuccessfulReading?.percent,
            charging: false,
            voltage: nil,
            stateText: lastSuccessfulReading == nil ? "Bluetooth not connected" : "Bluetooth reconnecting…",
            connectionText: "Bluetooth",
            requiresInputMonitoring: false,
            updatedAt: Date()
        ))
    }

    private func adopt(peripheral: CBPeripheral, using centralManager: CBCentralManager) {
        self.peripheral = peripheral
        peripheral.delegate = self

        if peripheral.state == .connected {
            peripheral.discoverServices([batteryServiceUUID])
        } else {
            centralManager.connect(peripheral, options: nil)
        }
    }

    private func isLikelyLofreePeripheral(_ peripheral: CBPeripheral) -> Bool {
        let name = (peripheral.name ?? "").lowercased()
        return name.contains("lofree") || name.contains("flow")
    }

    private func publish(_ reading: BatteryReading) {
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(reading)
        }
    }

    private func bluetoothUnavailableText(for state: CBManagerState) -> String {
        switch state {
        case .poweredOff:
            return "Bluetooth is off"
        case .unauthorized:
            return "Bluetooth access not allowed"
        case .unsupported:
            return "Bluetooth unavailable"
        case .resetting:
            return "Bluetooth resetting…"
        case .unknown:
            return "Starting Bluetooth…"
        case .poweredOn:
            return "Bluetooth ready"
        @unknown default:
            return "Bluetooth unavailable"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral == peripheral else { return }
        self.peripheral = nil
        self.batteryCharacteristic = nil
        publish(BatteryReading(
            percent: lastSuccessfulReading?.percent,
            charging: false,
            voltage: nil,
            stateText: "Bluetooth disconnected",
            connectionText: "Bluetooth",
            requiresInputMonitoring: false,
            updatedAt: Date()
        ))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == batteryServiceUUID {
            peripheral.discoverCharacteristics([batteryLevelCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == batteryLevelCharacteristicUUID {
            batteryCharacteristic = characteristic
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        guard characteristic.uuid == batteryLevelCharacteristicUUID else { return }
        guard let data = characteristic.value, let firstByte = data.first else { return }

        let reading = BatteryReading(
            percent: Int(firstByte),
            charging: false,
            voltage: nil,
            stateText: "Bluetooth connected",
            connectionText: "Bluetooth",
            requiresInputMonitoring: false,
            updatedAt: Date()
        )
        lastSuccessfulReading = reading
        publish(reading)
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
    private let dongleMonitor = DongleBatteryMonitor()
    private let bluetoothMonitor = BluetoothBatteryMonitor()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var dongleReading: BatteryReading?
    private var bluetoothReading: BatteryReading?
    private var reading = BatteryReading(
        percent: nil,
        charging: false,
        voltage: nil,
        stateText: "Starting…",
        connectionText: "2.4 GHz",
        requiresInputMonitoring: false,
        updatedAt: Date()
    )
    private var timer: Timer?
    private var hasShownPermissionAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusButton()

        dongleMonitor.onUpdate = { [weak self] reading in
            self?.dongleReading = reading
            self?.refreshDisplayedReading()
        }

        bluetoothMonitor.onUpdate = { [weak self] reading in
            self?.bluetoothReading = reading
            self?.refreshDisplayedReading()
        }

        refreshDisplayedReading()
        bluetoothMonitor.start()
        dongleMonitor.refresh()

        timer = Timer.scheduledTimer(withTimeInterval: Timing.steadyRefreshInterval, repeats: true) { [weak self] _ in
            self?.bluetoothMonitor.refresh()
            self?.dongleMonitor.refresh()
        }
    }

    private func refreshDisplayedReading() {
        if let chosen = selectReading() {
            reading = chosen
        }
        updateUI()
        maybeShowPermissionAlert()
    }

    private func selectReading() -> BatteryReading? {
        if let dongleReading, isActiveDongle(dongleReading) {
            return dongleReading
        }

        if let bluetoothReading, isActiveBluetooth(bluetoothReading) {
            return bluetoothReading
        }

        if let dongleReading, isPendingDongle(dongleReading), bluetoothReading?.percent == nil {
            return dongleReading
        }

        if let bluetoothReading {
            return bluetoothReading
        }

        return dongleReading
    }

    private func isActiveDongle(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "2.4 GHz connected", "2.4 GHz charging", "Refreshing 2.4 GHz battery…":
            return true
        default:
            return false
        }
    }

    private func isPendingDongle(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "Reading 2.4 GHz battery…", "Refreshing 2.4 GHz battery…":
            return true
        default:
            return false
        }
    }

    private func isActiveBluetooth(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "Bluetooth connected", "Refreshing Bluetooth battery…":
            return reading.percent != nil
        default:
            return false
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageTrailing
        button.imageHugsTitle = true

        if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Lofree battery") {
            image.isTemplate = true
            button.image = image
        }
    }

    private func updateUI() {
        let titleText: String
        if let percent = reading.percent {
            titleText = "\(percent)%"
        } else if reading.requiresInputMonitoring {
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
        } else {
            menu.addItem(withTitle: "Voltage: unavailable", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Connection: \(reading.connectionText)", action: nil, keyEquivalent: "")
        if reading.requiresInputMonitoring {
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

        if reading.requiresInputMonitoring {
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
        guard reading.requiresInputMonitoring else { return }
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

            Without this permission, the app cannot read the battery over 2.4 GHz and the percentage will not appear there.

            In this app, it is used only to ask the Lofree dongle for battery data. It does not capture, store, or send your keystrokes.

            If your keyboard is connected over Bluetooth instead, the app can read its battery there without this permission.

            To read the keyboard battery over 2.4 GHz, enable Input Monitoring for:

            Lofree Dongle Battery Access
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
        bluetoothMonitor.refresh()
        dongleMonitor.refresh()
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
