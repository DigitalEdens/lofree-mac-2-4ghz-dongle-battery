import AppKit
import CoreBluetooth
import Foundation
import IOKit.hid
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

private func appDisplayName() -> String {
    if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
       !displayName.isEmpty {
        return displayName
    }

    return "LofreeDongleBatteryDev"
}

final class DongleBatteryMonitor {
    private enum Timing {
        static let retryDelaySeconds: TimeInterval = 3
        static let overallReadTimeoutSeconds: TimeInterval = 15
    }

    private enum ReadResult {
        case success(BatteryReading)
        case timedOut
        case receiverNotFound
        case inputMonitoringRequired
    }

    var onUpdate: ((BatteryReading) -> Void)?

    private let queue = DispatchQueue(label: "com.digitaledens.lofreedonglebattery.dev.dongle")
    private var isReading = false
    private var lastSuccessfulReading: BatteryReading?
    private var retryWorkItem: DispatchWorkItem?

    func refresh() {
        retryWorkItem?.cancel()
        retryWorkItem = nil

        guard !isReading else { return }
        isReading = true

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

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.readDongleBattery()
            DispatchQueue.main.async {
                self.isReading = false
                self.handleReadResult(result)
            }
        }
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

    private func handleReadResult(_ result: ReadResult) {
        switch result {
        case .success(let reading):
            lastSuccessfulReading = reading
            publish(reading)
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
        }
    }

    private final class ReaderContext {
        var callbackBuffer = [UInt8](repeating: 0, count: 64)
        var callbackMessages = [[UInt8]]()
    }

    private func readDongleBattery() -> ReadResult {
        guard let device = matchingDongle() else {
            return .receiverNotFound
        }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return .inputMonitoringRequired
        }

        let context = ReaderContext()
        registerCallback(device, context: context)
        drainRunLoop(milliseconds: 100)

        let deadline = Date().addingTimeInterval(Timing.overallReadTimeoutSeconds)
        var reading: BatteryReading?
        while Date() < deadline, reading == nil {
            reading = runAttempt(device, context: context, deadline: deadline)
        }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        if let reading {
            return .success(reading)
        }

        return .timedOut
    }

    private func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return 0 }
        return (value as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return "" }
        return value as? String ?? ""
    }

    private func matchingDongle() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        return set.first(where: {
            let product = stringProperty($0, kIOHIDProductKey as CFString)
            let vendorID = intProperty($0, kIOHIDVendorIDKey as CFString)
            let productID = intProperty($0, kIOHIDProductIDKey as CFString)
            let usagePage = intProperty($0, kIOHIDPrimaryUsagePageKey as CFString)
            let usage = intProperty($0, kIOHIDPrimaryUsageKey as CFString)
            return (product.localizedCaseInsensitiveContains("2.4G Wireless Receiver")
                || (vendorID == 0x05ac && productID == 0x024f))
                && usagePage == 0x0c
                && usage == 0x01
        })
    }

    private func checksum(_ bytes: [UInt8]) -> UInt8 {
        let sum = bytes.dropLast().reduce(0) { ($0 + Int($1)) & 0xff }
        return UInt8((85 - sum) & 0xff)
    }

    private func commandPacket(_ command: UInt8, flag: UInt8 = 0x80, payload: [UInt8] = []) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 17)
        packet[0] = 0x08
        packet[1] = command
        packet[5] = flag
        for (index, value) in payload.prefix(10).enumerated() {
            packet[6 + index] = value
        }
        packet[16] = checksum(packet)
        return packet
    }

    private func command8Packet(address: Int, length: Int) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 17)
        packet[0] = 0x08
        packet[1] = 0x08
        packet[3] = UInt8((address >> 8) & 0xff)
        packet[4] = UInt8(address & 0xff)
        packet[5] = UInt8(length + 0x80)
        packet[16] = checksum(packet)
        return packet
    }

    private let windowsInit: [[UInt8]] = [
        [0x08, 0x03, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xca],
        [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0xe4, 0x05, 0x2a, 0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5e],
        [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x1d, 0x5e, 0x01, 0x56, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf2],
        [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0xd2, 0x14, 0xe1, 0xeb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12],
    ]

    private let windowsFollowUp: [[UInt8]] = [
        [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x50, 0xd5, 0x57, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8],
        [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x19, 0x55, 0x10, 0xef, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x57],
        [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x2b, 0x61, 0x4a, 0xe1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0d],
    ]

    private func drainRunLoop(milliseconds: Int) {
        let until = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func registerCallback(_ device: IOHIDDevice, context: ReaderContext) {
        IOHIDDeviceRegisterInputReportCallback(
            device,
            &context.callbackBuffer,
            context.callbackBuffer.count,
            { contextPointer, _, _, _, reportID, report, reportLength in
                guard let contextPointer else { return }
                let context = Unmanaged<ReaderContext>.fromOpaque(contextPointer).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                context.callbackMessages.append([UInt8(reportID)] + bytes)
            },
            Unmanaged.passUnretained(context).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func send(_ device: IOHIDDevice, _ packet: [UInt8], waitMs: Int) {
        packet.withUnsafeBytes { ptr in
            _ = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                8,
                ptr.bindMemory(to: UInt8.self).baseAddress!,
                packet.count
            )
        }
        drainRunLoop(milliseconds: waitMs)
    }

    private func timeRemainingMs(until deadline: Date) -> Int {
        max(0, Int(deadline.timeIntervalSinceNow * 1000))
    }

    @discardableResult
    private func sendUntilDeadline(_ device: IOHIDDevice, _ packet: [UInt8], waitMs: Int, deadline: Date) -> Bool {
        guard timeRemainingMs(until: deadline) > 0 else { return false }
        send(device, packet, waitMs: min(waitMs, timeRemainingMs(until: deadline)))
        return timeRemainingMs(until: deadline) > 0
    }

    private func extractBattery(from messages: [[UInt8]]) -> BatteryReading? {
        for message in messages {
            guard message.count >= 11 else { continue }
            guard message[0] == 0x08, message[1] == 0x08, message[2] == 0x04 else { continue }
            let percent = Int(message[7])
            let charging = message[8] == 1
            let voltage = (Int(message[9]) << 8) | Int(message[10])
            return BatteryReading(
                percent: percent,
                charging: charging,
                voltage: voltage,
                stateText: charging ? "2.4 GHz charging" : "2.4 GHz connected",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            )
        }
        return nil
    }

    private func runAttempt(_ device: IOHIDDevice, context: ReaderContext, deadline: Date) -> BatteryReading? {
        context.callbackMessages.removeAll()

        for packet in windowsInit {
            guard sendUntilDeadline(device, packet, waitMs: 250, deadline: deadline) else { return extractBattery(from: context.callbackMessages) }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        let webStyleWarmup: [[UInt8]] = [
            commandPacket(0x03),
            commandPacket(0x02, flag: 0x81, payload: [0x01]),
            command8Packet(address: 0, length: 10),
            command8Packet(address: 8496, length: 6),
            commandPacket(0x0e),
            commandPacket(0x12),
            commandPacket(0x1d),
            commandPacket(0x03),
        ]

        for packet in webStyleWarmup {
            guard sendUntilDeadline(device, packet, waitMs: 300, deadline: deadline) else { return extractBattery(from: context.callbackMessages) }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        for packet in windowsInit + windowsFollowUp {
            guard sendUntilDeadline(device, packet, waitMs: 250, deadline: deadline) else { return extractBattery(from: context.callbackMessages) }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        let batteryPacket = commandPacket(0x04)
        let onlinePacket = commandPacket(0x03)
        for _ in 0..<20 {
            guard sendUntilDeadline(device, batteryPacket, waitMs: 1200, deadline: deadline) else { return extractBattery(from: context.callbackMessages) }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
            drainRunLoop(milliseconds: min(500, timeRemainingMs(until: deadline)))
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
            guard sendUntilDeadline(device, onlinePacket, waitMs: 800, deadline: deadline) else { return extractBattery(from: context.callbackMessages) }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        return extractBattery(from: context.callbackMessages)
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
    private let appName = appDisplayName()

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

        if let dongleReading, readingPrefersDongle(dongleReading) {
            return dongleReading
        }

        if let bluetoothReading, isActiveBluetooth(bluetoothReading) {
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
        case "Reading 2.4 GHz battery…", "Refreshing 2.4 GHz battery…", "2.4 GHz retrying…", "2.4 GHz reconnecting…", "Allow Input Monitoring":
            return true
        default:
            return false
        }
    }

    private func isActiveBluetooth(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "Bluetooth connected":
            return reading.percent != nil
        case "Refreshing Bluetooth battery…", "Reading Bluetooth battery…":
            return true
        default:
            return false
        }
    }

    private func readingPrefersDongle(_ reading: BatteryReading) -> Bool {
        isPendingDongle(reading) || reading.stateText == "2.4 GHz receiver not found"
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
            menu.addItem(withTitle: "Enable: \(appName)", action: nil, keyEquivalent: "")
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

        let settingsItem = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringFromMenu), keyEquivalent: "")
        settingsItem.target = self
        if let image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Open Input Monitoring Settings") {
            image.isTemplate = true
            settingsItem.image = image
        }
        menu.addItem(settingsItem)
        menu.addItem(.separator())

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

            \(self.appName)
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
