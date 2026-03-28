import Foundation
import IOKit.hid

private let overallReadTimeoutSeconds: TimeInterval = 15

private enum ExitCode: Int32 {
    case success = 0
    case timedOut = 2
    case receiverNotFound = 10
    case inputMonitoringRequired = 11
}

struct BatteryReading {
    let percent: Int
    let charging: Bool
    let voltage: Int
}

var callbackBuffer = [UInt8](repeating: 0, count: 64)
var callbackMessages = [[UInt8]]()

func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
    guard let value = IOHIDDeviceGetProperty(device, key) else { return 0 }
    return (value as? NSNumber)?.intValue ?? 0
}

func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
    guard let value = IOHIDDeviceGetProperty(device, key) else { return "" }
    return value as? String ?? ""
}

func matchingDongle() -> IOHIDDevice? {
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

func checksum(_ bytes: [UInt8]) -> UInt8 {
    let sum = bytes.dropLast().reduce(0) { ($0 + Int($1)) & 0xff }
    return UInt8((85 - sum) & 0xff)
}

func commandPacket(_ command: UInt8, flag: UInt8 = 0x80, payload: [UInt8] = []) -> [UInt8] {
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

func command8Packet(address: Int, length: Int) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: 17)
    packet[0] = 0x08
    packet[1] = 0x08
    packet[3] = UInt8((address >> 8) & 0xff)
    packet[4] = UInt8(address & 0xff)
    packet[5] = UInt8(length + 0x80)
    packet[16] = checksum(packet)
    return packet
}

// These packets were captured from the official Windows utility and replayed on macOS
// to reliably prime the dongle before battery requests.
let windowsInit: [[UInt8]] = [
    [0x08, 0x03, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xca],
    [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0xe4, 0x05, 0x2a, 0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5e],
    [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x1d, 0x5e, 0x01, 0x56, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf2],
    [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0xd2, 0x14, 0xe1, 0xeb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12],
]

let windowsFollowUp: [[UInt8]] = [
    [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x50, 0xd5, 0x57, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8],
    [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x19, 0x55, 0x10, 0xef, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x57],
    [0x08, 0x01, 0x00, 0x00, 0x00, 0x88, 0x2b, 0x61, 0x4a, 0xe1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0d],
]

func drainRunLoop(milliseconds: Int) {
    let until = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

func registerCallback(_ device: IOHIDDevice) {
    IOHIDDeviceRegisterInputReportCallback(
        device,
        &callbackBuffer,
        callbackBuffer.count,
        { _, _, _, _, reportID, report, reportLength in
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            callbackMessages.append([UInt8(reportID)] + bytes)
        },
        nil
    )
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

func send(_ device: IOHIDDevice, _ packet: [UInt8], waitMs: Int) {
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

func timeRemainingMs(until deadline: Date) -> Int {
    max(0, Int(deadline.timeIntervalSinceNow * 1000))
}

@discardableResult
func sendUntilDeadline(_ device: IOHIDDevice, _ packet: [UInt8], waitMs: Int, deadline: Date) -> Bool {
    guard timeRemainingMs(until: deadline) > 0 else { return false }
    send(device, packet, waitMs: min(waitMs, timeRemainingMs(until: deadline)))
    return timeRemainingMs(until: deadline) > 0
}

func extractBattery(from messages: [[UInt8]]) -> BatteryReading? {
    for message in messages {
        guard message.count >= 11 else { continue }
        guard message[0] == 0x08, message[1] == 0x08, message[2] == 0x04 else { continue }
        let percent = Int(message[7])
        let charging = message[8] == 1
        let voltage = (Int(message[9]) << 8) | Int(message[10])
        return BatteryReading(percent: percent, charging: charging, voltage: voltage)
    }
    return nil
}

func runAttempt(_ device: IOHIDDevice, deadline: Date) -> BatteryReading? {
    callbackMessages.removeAll()

    for packet in windowsInit {
        guard sendUntilDeadline(device, packet, waitMs: 250, deadline: deadline) else { return extractBattery(from: callbackMessages) }
        if let reading = extractBattery(from: callbackMessages) { return reading }
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
        guard sendUntilDeadline(device, packet, waitMs: 300, deadline: deadline) else { return extractBattery(from: callbackMessages) }
        if let reading = extractBattery(from: callbackMessages) { return reading }
    }

    for packet in windowsInit + windowsFollowUp {
        guard sendUntilDeadline(device, packet, waitMs: 250, deadline: deadline) else { return extractBattery(from: callbackMessages) }
        if let reading = extractBattery(from: callbackMessages) { return reading }
    }

    let batteryPacket = commandPacket(0x04)
    let onlinePacket = commandPacket(0x03)
    for _ in 0..<20 {
        guard sendUntilDeadline(device, batteryPacket, waitMs: 1200, deadline: deadline) else { return extractBattery(from: callbackMessages) }
        if let reading = extractBattery(from: callbackMessages) { return reading }
        drainRunLoop(milliseconds: min(500, timeRemainingMs(until: deadline)))
        if let reading = extractBattery(from: callbackMessages) { return reading }
        guard sendUntilDeadline(device, onlinePacket, waitMs: 800, deadline: deadline) else { return extractBattery(from: callbackMessages) }
        if let reading = extractBattery(from: callbackMessages) { return reading }
    }

    return extractBattery(from: callbackMessages)
}

guard let device = matchingDongle() else {
    exit(ExitCode.receiverNotFound.rawValue)
}

let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    exit(ExitCode.inputMonitoringRequired.rawValue)
}

registerCallback(device)
drainRunLoop(milliseconds: 100)

let deadline = Date().addingTimeInterval(overallReadTimeoutSeconds)
var reading: BatteryReading?
while Date() < deadline, reading == nil {
    reading = runAttempt(device, deadline: deadline)
}

if let reading {
    print("BATTERY percent=\(reading.percent) charging=\(reading.charging ? 1 : 0) voltage=\(reading.voltage)")
    exit(ExitCode.success.rawValue)
}

exit(ExitCode.timedOut.rawValue)
