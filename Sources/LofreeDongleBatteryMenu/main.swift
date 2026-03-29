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

private func relativeUpdateText(since date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 5 {
        return "just now"
    }
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m ago"
    }
    let hours = minutes / 60
    return "\(hours)h ago"
}

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func exportTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date())
}

struct ReceiverCandidate {
    let identifier: String
    let product: String
    let manufacturer: String
    let vendorID: Int
    let productID: Int
    let usagePage: Int
    let usage: Int
    let locationID: Int

    var menuTitle: String {
        let name = product.isEmpty ? "Unknown HID device" : product
        return String(format: "%@ (VID 0x%04X PID 0x%04X)", name, vendorID, productID)
    }

    var reportLines: [String] {
        [
            "Product: \(product.isEmpty ? "unknown" : product)",
            "Manufacturer: \(manufacturer.isEmpty ? "unknown" : manufacturer)",
            String(format: "Vendor ID: 0x%04X", vendorID),
            String(format: "Product ID: 0x%04X", productID),
            String(format: "Usage Page: 0x%04X", usagePage),
            String(format: "Usage: 0x%04X", usage),
            String(format: "Location ID: 0x%08X", locationID),
            "Selection identifier: \(identifier)"
        ]
    }
}

private enum ConnectionMode: String {
    case auto
    case bluetoothOnly
    case dongleOnly

    var menuTitle: String {
        switch self {
        case .auto:
            return "Auto check"
        case .bluetoothOnly:
            return "Check Bluetooth only"
        case .dongleOnly:
            return "Check 2.4 GHz only"
        }
    }
}

final class DongleBatteryMonitor {
    struct CompatibilityReport {
        let text: String
    }

    private struct ProbeStep {
        let label: String
        let packet: [UInt8]
        let waitMs: Int
    }

    private struct ProbeProfile {
        let name: String
        let steps: [ProbeStep]
    }

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
    var selectedReceiverIdentifier: String?

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
                stateText: "Requesting fresh battery data…",
                connectionText: "2.4 GHz",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
        } else {
            publish(BatteryReading(
                percent: nil,
                charging: false,
                voltage: nil,
                stateText: "Requesting battery data…",
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

    func buildCompatibilityReport(metadata: [String], completion: @escaping (CompatibilityReport) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let report = self.generateCompatibilityReport(metadata: metadata)
            DispatchQueue.main.async {
                completion(report)
            }
        }
    }

    func buildProtocolExplorerReport(metadata: [String], completion: @escaping (CompatibilityReport) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let report = self.generateProtocolExplorerReport(metadata: metadata)
            DispatchQueue.main.async {
                completion(report)
            }
        }
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

    private func generateCompatibilityReport(metadata: [String]) -> CompatibilityReport {
        var lines: [String] = []
        lines.append("Lofree 2.4 GHz Compatibility Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("App: \(appDisplayName())")
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            lines.append("App version: \(version) (\(build))")
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
        for entry in metadata {
            lines.append(entry)
        }
        if let lastSuccessfulReading {
            lines.append("Last successful in-app 2.4 GHz reading: \(lastSuccessfulReading.percent.map { "\($0)%" } ?? "unavailable"), voltage \(lastSuccessfulReading.voltage.map { "\($0) mV" } ?? "unavailable"), status \(lastSuccessfulReading.stateText)")
        } else {
            lines.append("Last successful in-app 2.4 GHz reading: none")
        }
        lines.append("")

        guard let device = matchingDongle() else {
            lines.append("Result: No matching 2.4 GHz receiver found")
            let candidates = receiverCandidates()
            if candidates.isEmpty {
                lines.append("Likely HID receiver candidates: none")
            } else {
                lines.append("")
                lines.append("Likely HID receiver candidates")
                for (index, candidate) in candidates.enumerated() {
                    lines.append("\(index + 1). \(candidate.menuTitle)")
                    for line in candidate.reportLines {
                        lines.append("   \(line)")
                    }
                }
            }
            return CompatibilityReport(text: lines.joined(separator: "\n"))
        }

        let candidate = candidate(for: device)

        lines.append("Selected receiver")
        for line in candidate.reportLines {
            lines.append(line)
        }
        lines.append("")

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        lines.append("IOHIDDeviceOpen result: \(openResult)")
        if openResult != kIOReturnSuccess {
            lines.append("Result: Input Monitoring likely required or device open failed")
            return CompatibilityReport(text: lines.joined(separator: "\n"))
        }

        let context = ReaderContext()
        registerCallback(device, context: context)
        drainRunLoop(milliseconds: 100)

        var sentPackets: [(String, [UInt8])] = []
        let deadline = Date().addingTimeInterval(Timing.overallReadTimeoutSeconds)
        let decodedReading = runCompatibilityAttempt(device, context: context, deadline: deadline) { label, packet in
            sentPackets.append((label, packet))
        }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        lines.append("Sent packets")
        if sentPackets.isEmpty {
            lines.append("- none")
        } else {
            for (index, entry) in sentPackets.enumerated() {
                lines.append("\(index + 1). \(entry.0) [\(entry.1.count) bytes]")
                lines.append("   \(hexString(entry.1))")
            }
        }
        lines.append("")

        lines.append("Received packets")
        if context.callbackMessages.isEmpty {
            lines.append("- none")
        } else {
            for (index, message) in context.callbackMessages.enumerated() {
                let isBatteryCandidate =
                    message.count >= 11 &&
                    message[0] == 0x08 &&
                    message[1] == 0x08 &&
                    message[2] == 0x04
                let suffix = isBatteryCandidate ? " [battery-candidate]" : ""
                lines.append("\(index + 1). [\(message.count) bytes]\(suffix)")
                lines.append("   \(hexString(message))")
            }
        }
        lines.append("")

        if !context.callbackMessages.isEmpty {
            lines.append("Received packet family summary")
            let families = Dictionary(grouping: context.callbackMessages) { message -> String in
                let prefix = Array(message.prefix(3))
                return hexString(prefix)
            }
            for key in families.keys.sorted() {
                let count = families[key]?.count ?? 0
                lines.append("- \(key): \(count) packet(s)")
            }
            lines.append("- Expected Flow Lite100 battery family: 08 08 04")
            let sawExpectedFamily = context.callbackMessages.contains { message in
                message.count >= 3 && message[0] == 0x08 && message[1] == 0x08 && message[2] == 0x04
            }
            lines.append("- Observed expected battery family: \(sawExpectedFamily ? "yes" : "no")")
            lines.append("")
        }

        var summary: [String] = []
        summary.append("Summary verdict")
        summary.append("- Receiver matched: yes")
        summary.append("- IOHID open succeeded: \(openResult == kIOReturnSuccess ? "yes" : "no")")
        let sawExpectedFamily = context.callbackMessages.contains { message in
            message.count >= 3 && message[0] == 0x08 && message[1] == 0x08 && message[2] == 0x04
        }
        summary.append("- Expected battery packet family observed: \(sawExpectedFamily ? "yes" : "no")")

        if let decodedReading {
            summary.append("- Battery decode succeeded: yes")
            summary.append("- Decoded percent: \(decodedReading.percent.map(String.init) ?? "unavailable")")
            summary.append("- Decoded voltage: \(decodedReading.voltage.map(String.init) ?? "unavailable")")
            lines.append(contentsOf: summary)
            lines.append("")
            lines.append("Decoded battery reading")
            lines.append("Percent: \(decodedReading.percent.map(String.init) ?? "unavailable")")
            lines.append("Charging: \(decodedReading.charging ? "yes" : "no")")
            lines.append("Voltage: \(decodedReading.voltage.map { "\($0) mV" } ?? "unavailable")")
        } else {
            summary.append("- Battery decode succeeded: no")
            lines.append(contentsOf: summary)
            lines.append("")
            lines.append("Decoded battery reading")
            lines.append("No battery packet was decoded with the current Flow Lite100 logic")
        }

        return CompatibilityReport(text: lines.joined(separator: "\n"))
    }

    private func generateProtocolExplorerReport(metadata: [String]) -> CompatibilityReport {
        var lines: [String] = []
        lines.append("Lofree 2.4 GHz Protocol Explorer Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("App: \(appDisplayName())")
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            lines.append("App version: \(version) (\(build))")
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
        for entry in metadata {
            lines.append(entry)
        }
        lines.append("")

        guard let device = matchingDongle() else {
            lines.append("Result: No matching 2.4 GHz receiver found")
            let candidates = receiverCandidates()
            if candidates.isEmpty {
                lines.append("Likely HID receiver candidates: none")
            } else {
                lines.append("")
                lines.append("Likely HID receiver candidates")
                for (index, candidate) in candidates.enumerated() {
                    lines.append("\(index + 1). \(candidate.menuTitle)")
                    for line in candidate.reportLines {
                        lines.append("   \(line)")
                    }
                }
            }
            return CompatibilityReport(text: lines.joined(separator: "\n"))
        }

        let candidate = candidate(for: device)
        lines.append("Selected receiver")
        for line in candidate.reportLines {
            lines.append(line)
        }
        lines.append("")

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        lines.append("IOHIDDeviceOpen result: \(openResult)")
        if openResult != kIOReturnSuccess {
            lines.append("Result: Input Monitoring likely required or device open failed")
            return CompatibilityReport(text: lines.joined(separator: "\n"))
        }

        let context = ReaderContext()
        registerCallback(device, context: context)
        drainRunLoop(milliseconds: 100)

        for profile in probeProfiles() {
            context.callbackMessages.removeAll()
            var sentPackets: [(String, [UInt8])] = []
            let deadline = Date().addingTimeInterval(6)
            let decodedReading = runProbeProfile(device, context: context, steps: profile.steps, deadline: deadline) { label, packet in
                sentPackets.append((label, packet))
            }
            let messages = context.callbackMessages

            lines.append("Profile: \(profile.name)")
            lines.append("Sent packet count: \(sentPackets.count)")
            lines.append("Received packet count: \(messages.count)")

            if !messages.isEmpty {
                let families = Dictionary(grouping: messages) { message -> String in
                    hexString(Array(message.prefix(3)))
                }
                lines.append("Packet family summary")
                for key in families.keys.sorted() {
                    let count = families[key]?.count ?? 0
                    lines.append("- \(key): \(count) packet(s)")
                }
            } else {
                lines.append("Packet family summary")
                lines.append("- none")
            }

            if let decodedReading {
                lines.append("Decoder result: percent \(decodedReading.percent.map(String.init) ?? "unavailable"), voltage \(decodedReading.voltage.map { "\($0) mV" } ?? "unavailable"), status \(decodedReading.stateText)")
            } else {
                lines.append("Decoder result: no battery packet decoded with current Flow Lite100 logic")
            }

            let sentPreview = sentPackets.prefix(12)
            if !sentPreview.isEmpty {
                lines.append("Sent packets (preview)")
                for (index, entry) in sentPreview.enumerated() {
                    lines.append("\(index + 1). \(entry.0) [\(entry.1.count) bytes]")
                    lines.append("   \(hexString(entry.1))")
                }
            }

            let receivedPreview = messages.prefix(24)
            if !receivedPreview.isEmpty {
                lines.append("Received packets (preview)")
                for (index, message) in receivedPreview.enumerated() {
                    let isBatteryCandidate =
                        message.count >= 11 &&
                        message[0] == 0x08 &&
                        message[1] == 0x08 &&
                        message[2] == 0x04
                    let suffix = isBatteryCandidate ? " [battery-candidate]" : ""
                    lines.append("\(index + 1). [\(message.count) bytes]\(suffix)")
                    lines.append("   \(hexString(message))")
                }
            }

            lines.append("")
            drainRunLoop(milliseconds: 200)
        }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        return CompatibilityReport(text: lines.joined(separator: "\n"))
    }

    private func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return 0 }
        return (value as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return "" }
        return value as? String ?? ""
    }

    private func allHIDDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        return Array(set)
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var entryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        return entryID
    }

    private func candidate(for device: IOHIDDevice) -> ReceiverCandidate {
        let product = stringProperty(device, kIOHIDProductKey as CFString)
        let manufacturer = stringProperty(device, kIOHIDManufacturerKey as CFString)
        let vendorID = intProperty(device, kIOHIDVendorIDKey as CFString)
        let productID = intProperty(device, kIOHIDProductIDKey as CFString)
        let usagePage = intProperty(device, kIOHIDPrimaryUsagePageKey as CFString)
        let usage = intProperty(device, kIOHIDPrimaryUsageKey as CFString)
        let locationID = intProperty(device, kIOHIDLocationIDKey as CFString)
        let identifier = String(format: "%016llX", registryID(device))
        return ReceiverCandidate(
            identifier: identifier,
            product: product,
            manufacturer: manufacturer,
            vendorID: vendorID,
            productID: productID,
            usagePage: usagePage,
            usage: usage,
            locationID: locationID
        )
    }

    private func isLikelyReceiverCandidate(_ candidate: ReceiverCandidate) -> Bool {
        let product = candidate.product.lowercased()
        let manufacturer = candidate.manufacturer.lowercased()
        if product.contains("receiver") || product.contains("dongle") || product.contains("lofree") || product.contains("flow") {
            return true
        }
        if manufacturer.contains("lofree") || manufacturer.contains("cx") {
            return true
        }
        if candidate.vendorID == 0x05ac && candidate.productID == 0x024f {
            return true
        }
        if candidate.usagePage == 0x0c && candidate.usage == 0x01 {
            return true
        }
        return false
    }

    func receiverCandidates() -> [ReceiverCandidate] {
        allHIDDevices()
            .map(candidate(for:))
            .filter(isLikelyReceiverCandidate)
            .sorted { lhs, rhs in
                if lhs.product != rhs.product { return lhs.product < rhs.product }
                if lhs.vendorID != rhs.vendorID { return lhs.vendorID < rhs.vendorID }
                if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
                return lhs.identifier < rhs.identifier
            }
    }

    private func matchingDongle() -> IOHIDDevice? {
        let devices = allHIDDevices()

        if let selectedReceiverIdentifier, !selectedReceiverIdentifier.isEmpty {
            if let manuallyChosen = devices.first(where: { candidate(for: $0).identifier == selectedReceiverIdentifier }) {
                return manuallyChosen
            }
        }

        return devices.first(where: {
            let candidate = candidate(for: $0)
            let product = candidate.product
            let vendorID = candidate.vendorID
            let productID = candidate.productID
            let usagePage = candidate.usagePage
            let usage = candidate.usage
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

    private func runCompatibilityAttempt(
        _ device: IOHIDDevice,
        context: ReaderContext,
        deadline: Date,
        packetLogger: (String, [UInt8]) -> Void
    ) -> BatteryReading? {
        context.callbackMessages.removeAll()

        for (index, packet) in windowsInit.enumerated() {
            packetLogger("windowsInit[\(index)]", packet)
            guard sendUntilDeadline(device, packet, waitMs: 250, deadline: deadline) else {
                return extractBattery(from: context.callbackMessages)
            }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        let webStyleWarmup: [(String, [UInt8])] = [
            ("commandPacket(0x03)", commandPacket(0x03)),
            ("commandPacket(0x02, flag:0x81, payload:[0x01])", commandPacket(0x02, flag: 0x81, payload: [0x01])),
            ("command8Packet(address:0, length:10)", command8Packet(address: 0, length: 10)),
            ("command8Packet(address:8496, length:6)", command8Packet(address: 8496, length: 6)),
            ("commandPacket(0x0e)", commandPacket(0x0e)),
            ("commandPacket(0x12)", commandPacket(0x12)),
            ("commandPacket(0x1d)", commandPacket(0x1d)),
            ("commandPacket(0x03)", commandPacket(0x03)),
        ]

        for (label, packet) in webStyleWarmup {
            packetLogger(label, packet)
            guard sendUntilDeadline(device, packet, waitMs: 300, deadline: deadline) else {
                return extractBattery(from: context.callbackMessages)
            }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        for (index, packet) in (windowsInit + windowsFollowUp).enumerated() {
            packetLogger("windowsReplay[\(index)]", packet)
            guard sendUntilDeadline(device, packet, waitMs: 250, deadline: deadline) else {
                return extractBattery(from: context.callbackMessages)
            }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        let batteryPacket = commandPacket(0x04)
        let onlinePacket = commandPacket(0x03)
        for iteration in 0..<20 {
            packetLogger("batteryPacket[\(iteration)]", batteryPacket)
            guard sendUntilDeadline(device, batteryPacket, waitMs: 1200, deadline: deadline) else {
                return extractBattery(from: context.callbackMessages)
            }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
            drainRunLoop(milliseconds: min(500, timeRemainingMs(until: deadline)))
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
            packetLogger("onlinePacket[\(iteration)]", onlinePacket)
            guard sendUntilDeadline(device, onlinePacket, waitMs: 800, deadline: deadline) else {
                return extractBattery(from: context.callbackMessages)
            }
            if let reading = extractBattery(from: context.callbackMessages) { return reading }
        }

        return extractBattery(from: context.callbackMessages)
    }

    private func runProbeProfile(
        _ device: IOHIDDevice,
        context: ReaderContext,
        steps: [ProbeStep],
        deadline: Date,
        packetLogger: (String, [UInt8]) -> Void
    ) -> BatteryReading? {
        for step in steps {
            packetLogger(step.label, step.packet)
            guard sendUntilDeadline(device, step.packet, waitMs: step.waitMs, deadline: deadline) else {
                return extractBattery(from: context.callbackMessages)
            }
            if let reading = extractBattery(from: context.callbackMessages) {
                return reading
            }
        }
        return extractBattery(from: context.callbackMessages)
    }

    private func probeProfiles() -> [ProbeProfile] {
        let webStyleWarmup: [ProbeStep] = [
            ProbeStep(label: "commandPacket(0x03)", packet: commandPacket(0x03), waitMs: 300),
            ProbeStep(label: "commandPacket(0x02, flag:0x81, payload:[0x01])", packet: commandPacket(0x02, flag: 0x81, payload: [0x01]), waitMs: 300),
            ProbeStep(label: "command8Packet(address:0, length:10)", packet: command8Packet(address: 0, length: 10), waitMs: 300),
            ProbeStep(label: "command8Packet(address:8496, length:6)", packet: command8Packet(address: 8496, length: 6), waitMs: 300),
            ProbeStep(label: "commandPacket(0x0e)", packet: commandPacket(0x0e), waitMs: 300),
            ProbeStep(label: "commandPacket(0x12)", packet: commandPacket(0x12), waitMs: 300),
            ProbeStep(label: "commandPacket(0x1d)", packet: commandPacket(0x1d), waitMs: 300),
            ProbeStep(label: "commandPacket(0x03)", packet: commandPacket(0x03), waitMs: 300),
        ]

        let fullBaseline = ProbeProfile(
            name: "Flow Lite100 baseline",
            steps:
                windowsInit.enumerated().map { ProbeStep(label: "windowsInit[\($0.offset)]", packet: $0.element, waitMs: 250) } +
                webStyleWarmup +
                (windowsInit + windowsFollowUp).enumerated().map { ProbeStep(label: "windowsReplay[\($0.offset)]", packet: $0.element, waitMs: 250) } +
                [
                    ProbeStep(label: "batteryPacket[0]", packet: commandPacket(0x04), waitMs: 1200),
                    ProbeStep(label: "onlinePacket[0]", packet: commandPacket(0x03), waitMs: 800),
                    ProbeStep(label: "batteryPacket[1]", packet: commandPacket(0x04), waitMs: 1200),
                    ProbeStep(label: "onlinePacket[1]", packet: commandPacket(0x03), waitMs: 800),
                ]
        )

        let quickBattery = ProbeProfile(
            name: "Quick battery poll",
            steps: [
                ProbeStep(label: "commandPacket(0x03)", packet: commandPacket(0x03), waitMs: 250),
                ProbeStep(label: "commandPacket(0x04)", packet: commandPacket(0x04), waitMs: 1000),
                ProbeStep(label: "commandPacket(0x03)", packet: commandPacket(0x03), waitMs: 700),
                ProbeStep(label: "commandPacket(0x04)", packet: commandPacket(0x04), waitMs: 1000),
            ]
        )

        let warmupOnly = ProbeProfile(
            name: "Warmup then single battery request",
            steps:
                windowsInit.enumerated().map { ProbeStep(label: "windowsInit[\($0.offset)]", packet: $0.element, waitMs: 250) } +
                webStyleWarmup +
                [ProbeStep(label: "commandPacket(0x04)", packet: commandPacket(0x04), waitMs: 1000)]
        )

        let commandSweep = ProbeProfile(
            name: "Single-command sweep",
            steps: [
                ProbeStep(label: "commandPacket(0x02, flag:0x81, payload:[0x01])", packet: commandPacket(0x02, flag: 0x81, payload: [0x01]), waitMs: 350),
                ProbeStep(label: "commandPacket(0x03)", packet: commandPacket(0x03), waitMs: 350),
                ProbeStep(label: "commandPacket(0x04)", packet: commandPacket(0x04), waitMs: 1000),
                ProbeStep(label: "commandPacket(0x0e)", packet: commandPacket(0x0e), waitMs: 350),
                ProbeStep(label: "commandPacket(0x12)", packet: commandPacket(0x12), waitMs: 350),
                ProbeStep(label: "commandPacket(0x1d)", packet: commandPacket(0x1d), waitMs: 350),
            ]
        )

        return [fullBaseline, quickBattery, warmupOnly, commandSweep]
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
                    stateText: "Requesting fresh battery data…",
                    connectionText: "Bluetooth",
                    requiresInputMonitoring: false,
                    updatedAt: Date()
                ))
            } else {
                publish(BatteryReading(
                    percent: nil,
                    charging: false,
                    voltage: nil,
                    stateText: "Requesting battery data…",
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
            publish(BatteryReading(
                percent: lastSuccessfulReading?.percent,
                charging: false,
                voltage: nil,
                stateText: lastSuccessfulReading == nil ? "Requesting battery data…" : "Requesting fresh battery data…",
                connectionText: "Bluetooth",
                requiresInputMonitoring: false,
                updatedAt: Date()
            ))
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

    private enum Compatibility {
        static let reportTitle = "Export 2.4 GHz Compatibility Report…"
        static let explorerTitle = "Export 2.4 GHz Protocol Explorer…"
    }

    private enum DefaultsKey {
        static let connectionMode = "ConnectionMode"
        static let receiverIdentifier = "ReceiverIdentifier"
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
    private var availableReceivers: [ReceiverCandidate] = []
    private var connectionMode: ConnectionMode = {
        guard let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.connectionMode),
              let mode = ConnectionMode(rawValue: rawValue) else {
            return .auto
        }
        return mode
    }()
    private var selectedReceiverIdentifier: String? = UserDefaults.standard.string(forKey: DefaultsKey.receiverIdentifier)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusButton()
        syncAvailableReceivers()
        dongleMonitor.selectedReceiverIdentifier = selectedReceiverIdentifier

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
            self?.refreshForCurrentMode()
        }
    }

    private func refreshDisplayedReading() {
        syncAvailableReceivers()
        if let chosen = selectReading() {
            reading = chosen
        }
        updateUI()
        maybeShowPermissionAlert()
    }

    private func selectReading() -> BatteryReading? {
        switch connectionMode {
        case .bluetoothOnly:
            return selectBluetoothReading()
        case .dongleOnly:
            return selectDongleReading()
        case .auto:
            break
        }

        if let dongleReading = selectDongleReading(activeOnly: true) {
            return dongleReading
        }

        if let bluetoothReading = selectBluetoothReading(activeOnly: true) {
            return bluetoothReading
        }

        if let dongleReading = selectDongleReading() {
            return dongleReading
        }

        return bluetoothReading
    }

    private func selectBluetoothReading(activeOnly: Bool = false) -> BatteryReading? {
        guard let bluetoothReading else { return nil }

        if isActiveBluetooth(bluetoothReading) {
            return bluetoothReading
        }

        return activeOnly ? nil : bluetoothReading
    }

    private func selectDongleReading(activeOnly: Bool = false) -> BatteryReading? {
        guard let dongleReading else { return nil }

        if isActiveDongle(dongleReading) {
            return dongleReading
        }

        if readingPrefersDongle(dongleReading) {
            return dongleReading
        }

        return activeOnly ? nil : dongleReading
    }

    private func isActiveDongle(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "2.4 GHz connected", "2.4 GHz charging":
            return true
        default:
            return false
        }
    }

    private func isPendingDongle(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "Requesting battery data…", "Requesting fresh battery data…", "2.4 GHz retrying…", "2.4 GHz reconnecting…", "Allow Input Monitoring":
            return true
        default:
            return false
        }
    }

    private func isActiveBluetooth(_ reading: BatteryReading) -> Bool {
        switch reading.stateText {
        case "Bluetooth connected":
            return reading.percent != nil
        case "Requesting fresh battery data…", "Requesting battery data…", "Bluetooth reconnecting…":
            return true
        default:
            return false
        }
    }

    private func readingPrefersDongle(_ reading: BatteryReading) -> Bool {
        isPendingDongle(reading) || reading.stateText == "2.4 GHz receiver not found"
    }

    private func refreshForCurrentMode() {
        syncAvailableReceivers()
        dongleMonitor.selectedReceiverIdentifier = selectedReceiverIdentifier
        switch connectionMode {
        case .auto:
            bluetoothMonitor.refresh()
            dongleMonitor.refresh()
        case .bluetoothOnly:
            bluetoothMonitor.refresh()
        case .dongleOnly:
            dongleMonitor.refresh()
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
        if let percent = reading.percent {
            menu.addItem(withTitle: "Battery: \(percent)%", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Battery: unavailable", action: nil, keyEquivalent: "")
        }
        if let voltage = reading.voltage {
            menu.addItem(withTitle: "Voltage: \(voltage) mV", action: nil, keyEquivalent: "")
        } else if reading.connectionText == "Bluetooth" {
            menu.addItem(withTitle: "Voltage: unavailable on Bluetooth", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Voltage: unavailable", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Last updated: \(relativeUpdateText(since: reading.updatedAt))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check Mode: \(connectionMode.menuTitle)", action: nil, keyEquivalent: "")
        let selectedReceiverTitle = selectedReceiverDisplayName()
        menu.addItem(withTitle: "2.4 GHz Receiver: \(selectedReceiverTitle)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Current Connection Type: \(reading.connectionText)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Status: \(reading.stateText)", action: nil, keyEquivalent: "")
        if reading.requiresInputMonitoring {
            menu.addItem(withTitle: "Enable: \(appName)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())

        let autoModeItem = NSMenuItem(title: ConnectionMode.auto.menuTitle, action: #selector(setConnectionMode(_:)), keyEquivalent: "")
        autoModeItem.target = self
        autoModeItem.representedObject = ConnectionMode.auto.rawValue
        autoModeItem.state = connectionMode == .auto ? .on : .off
        menu.addItem(autoModeItem)

        let bluetoothModeItem = NSMenuItem(title: ConnectionMode.bluetoothOnly.menuTitle, action: #selector(setConnectionMode(_:)), keyEquivalent: "")
        bluetoothModeItem.target = self
        bluetoothModeItem.representedObject = ConnectionMode.bluetoothOnly.rawValue
        bluetoothModeItem.state = connectionMode == .bluetoothOnly ? .on : .off
        menu.addItem(bluetoothModeItem)

        let dongleModeItem = NSMenuItem(title: ConnectionMode.dongleOnly.menuTitle, action: #selector(setConnectionMode(_:)), keyEquivalent: "")
        dongleModeItem.target = self
        dongleModeItem.representedObject = ConnectionMode.dongleOnly.rawValue
        dongleModeItem.state = connectionMode == .dongleOnly ? .on : .off
        menu.addItem(dongleModeItem)

        menu.addItem(.separator())
        for candidate in availableReceivers {
            let item = NSMenuItem(title: candidate.menuTitle, action: #selector(setReceiverSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.identifier
            item.state = candidate.identifier == selectedReceiverIdentifier ? .on : .off
            menu.addItem(item)
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

        let reportItem = NSMenuItem(title: Compatibility.reportTitle, action: #selector(exportCompatibilityReport), keyEquivalent: "")
        reportItem.target = self
        if let image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: Compatibility.reportTitle) {
            image.isTemplate = true
            reportItem.image = image
        }
        menu.addItem(reportItem)

        let explorerItem = NSMenuItem(title: Compatibility.explorerTitle, action: #selector(exportProtocolExplorerReport), keyEquivalent: "")
        explorerItem.target = self
        if let image = NSImage(systemSymbolName: "waveform.path.ecg.rectangle", accessibilityDescription: Compatibility.explorerTitle) {
            image.isTemplate = true
            explorerItem.image = image
        }
        menu.addItem(explorerItem)
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
        refreshForCurrentMode()
    }

    @objc private func exportCompatibilityReport() {
        let panel = NSSavePanel()
        panel.title = "Export 2.4 GHz Compatibility Report"
        panel.nameFieldStringValue = "Lofree-2.4GHz-Compatibility-\(exportTimestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let metadata = [
            "Trigger: Manual export",
            "Current check mode: \(connectionMode.menuTitle)",
            "Selected 2.4 GHz receiver: \(selectedReceiverDisplayName())",
            "Current connection type shown in app: \(reading.connectionText)",
            "Current status shown in app: \(reading.stateText)",
            "Current battery shown in app: \(reading.percent.map { "\($0)%" } ?? "unavailable")",
            "Current voltage shown in app: \(reading.voltage.map { "\($0) mV" } ?? (reading.connectionText == "Bluetooth" ? "unavailable on Bluetooth" : "unavailable"))",
            "Input Monitoring currently required by app: \(reading.requiresInputMonitoring ? "yes" : "no")"
        ]

        dongleMonitor.buildCompatibilityReport(metadata: metadata) { [weak self] report in
            do {
                try report.text.write(to: url, atomically: true, encoding: .utf8)
                let alert = NSAlert()
                alert.messageText = "Compatibility Report Saved"
                alert.informativeText = "Saved the 2.4 GHz compatibility report to:\n\n\(url.path)\n\nYou can send this file to help me add support for other Lofree models."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Reveal in Finder")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could Not Save Report"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self?.refreshDisplayedReading()
        }
    }

    @objc private func exportProtocolExplorerReport() {
        let panel = NSSavePanel()
        panel.title = "Export 2.4 GHz Protocol Explorer Report"
        panel.nameFieldStringValue = "Lofree-2.4GHz-Protocol-Explorer-\(exportTimestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let metadata = [
            "Trigger: Manual protocol explorer export",
            "Current check mode: \(connectionMode.menuTitle)",
            "Selected 2.4 GHz receiver: \(selectedReceiverDisplayName())",
            "Current connection type shown in app: \(reading.connectionText)",
            "Current status shown in app: \(reading.stateText)",
            "Current battery shown in app: \(reading.percent.map { "\($0)%" } ?? "unavailable")",
            "Current voltage shown in app: \(reading.voltage.map { "\($0) mV" } ?? (reading.connectionText == "Bluetooth" ? "unavailable on Bluetooth" : "unavailable"))"
        ]

        dongleMonitor.buildProtocolExplorerReport(metadata: metadata) { [weak self] report in
            do {
                try report.text.write(to: url, atomically: true, encoding: .utf8)
                let alert = NSAlert()
                alert.messageText = "Protocol Explorer Report Saved"
                alert.informativeText = "Saved the 2.4 GHz protocol explorer report to:\n\n\(url.path)\n\nYou can send this file to help me figure out the protocol for unsupported Lofree receivers."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Reveal in Finder")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could Not Save Report"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self?.refreshDisplayedReading()
        }
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

    @objc private func setConnectionMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = ConnectionMode(rawValue: rawValue) else { return }
        connectionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.connectionMode)
        refreshForCurrentMode()
        refreshDisplayedReading()
    }

    @objc private func setReceiverSelection(_ sender: NSMenuItem) {
        let identifier = (sender.representedObject as? String) ?? ""
        selectedReceiverIdentifier = identifier.isEmpty ? nil : identifier
        if let selectedReceiverIdentifier {
            UserDefaults.standard.set(selectedReceiverIdentifier, forKey: DefaultsKey.receiverIdentifier)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.receiverIdentifier)
        }
        dongleMonitor.selectedReceiverIdentifier = selectedReceiverIdentifier
        refreshForCurrentMode()
        refreshDisplayedReading()
    }

    @objc private func openSupportLink() {
        guard let url = URL(string: Support.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func syncAvailableReceivers() {
        availableReceivers = dongleMonitor.receiverCandidates()
        if let selectedReceiverIdentifier,
           !availableReceivers.contains(where: { $0.identifier == selectedReceiverIdentifier }) {
            self.selectedReceiverIdentifier = nil
            UserDefaults.standard.removeObject(forKey: DefaultsKey.receiverIdentifier)
            dongleMonitor.selectedReceiverIdentifier = nil
        }
    }

    private func selectedReceiverDisplayName() -> String {
        guard let selectedReceiverIdentifier, !selectedReceiverIdentifier.isEmpty else {
            return "Auto detect"
        }
        if let candidate = availableReceivers.first(where: { $0.identifier == selectedReceiverIdentifier }) {
            return candidate.menuTitle
        }
        return "Manual selection"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
