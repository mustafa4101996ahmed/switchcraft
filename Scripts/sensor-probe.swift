// Minimal native accelerometer probe. No keyboard access, no root.
//
//   xcrun swiftc -O Scripts/sensor-probe.swift -o build/sensor-probe && build/sensor-probe 3
//
// Lists the SPU HID devices, opens the accelerometer (page 0xFF00, usage 3), wakes it,
// streams for N seconds and reports the measured rate and a few parsed samples.
// Approach from olvvier/apple-silicon-accelerometer (MIT) — see LICENSES/.

import Foundation
import IOKit
import IOKit.hid

func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "3") ?? 3

// 1. Enumerate (no permission needed).
var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator)
var service = IOIteratorNext(iterator)
print("AppleSPUHIDDevice services:")
while service != 0 {
    func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
    print(String(format: "  %-12@ page 0x%04X usage %3d  maxReport %@", (prop("Product") as? String ?? "?") as NSString,
                 prop("PrimaryUsagePage") as? Int ?? 0, prop("PrimaryUsage") as? Int ?? 0, "\(prop("MaxInputReportSize") ?? "?")"))
    IOObjectRelease(service)
    service = IOIteratorNext(iterator)
}
IOObjectRelease(iterator)

// 2. Open the accelerometer.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3, kIOHIDTransportKey: "SPU"] as CFDictionary)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen:", hex(openResult))
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
guard openResult == kIOReturnSuccess, !devices.isEmpty else {
    print("RESULT: accelerometer not available (UNSUPPORTED_SENSOR or SENSOR_PERMISSION_REQUIRED)")
    exit(1)
}

// 3. Wake + stream.
struct Stats { var count = 0; var first: UInt64 = 0; var last: UInt64 = 0; var samples: [(Double, Double, Double)] = [] }
nonisolated(unsafe) var stats = Stats()
let callback: IOHIDReportWithTimeStampCallback = { _, _, _, _, _, report, length, timestamp in
    guard length == 22 else { return }
    stats.count += 1
    if stats.first == 0 { stats.first = timestamp }
    stats.last = timestamp
    if stats.samples.count < 5 {
        func axis(_ offset: Int) -> Double {
            Double(Int32(littleEndian: UnsafeRawPointer(report).loadUnaligned(fromByteOffset: offset, as: Int32.self))) / 65536
        }
        stats.samples.append((axis(6), axis(10), axis(14)))
    }
}
// After a restart the sensor stays silent until the wake properties reach the AppleSPUHIDDriver
// service. Writing them to the HID device (IOHIDDeviceSetProperty) is accepted but doesn't wake it.
var driverIterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &driverIterator)
var driver = IOIteratorNext(driverIterator)
while driver != 0 {
    func prop(_ key: String) -> Int? { IORegistryEntryCreateCFProperty(driver, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int }
    if prop("PrimaryUsagePage") == 0xFF00 && prop("PrimaryUsage") == 3 {
        for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
            print("  set \(key) on AppleSPUHIDDriver:", hex(IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)))
        }
    }
    IOObjectRelease(driver)
    driver = IOIteratorNext(driverIterator)
}
IOObjectRelease(driverIterator)
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
for device in devices {
    IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, 4096, callback, nil)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}
CFRunLoopRunInMode(.defaultMode, seconds, false)

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let span = Double(stats.last &- stats.first) * Double(timebase.numer) / Double(timebase.denom) / 1e9
print("Reports:", stats.count, String(format: "over %.2f s → %.1f Hz (measured)", span, span > 0 ? Double(stats.count - 1) / span : 0))
for s in stats.samples { print(String(format: "  x %+.4f g  y %+.4f g  z %+.4f g  |a| %.4f g", s.0, s.1, s.2, (s.0 * s.0 + s.1 * s.1 + s.2 * s.2).squareRoot())) }
print(stats.count > 0 ? "RESULT: SUPPORTED — direct access works without root" : "RESULT: SENSOR_PERMISSION_REQUIRED — opened but no data")
exit(stats.count > 0 ? 0 : 2)
