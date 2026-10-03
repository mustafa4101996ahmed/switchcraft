import Foundation
import IOKit
import IOKit.ps

/// What this Mac is, detected once at launch. Opens no devices and needs no permission.
struct HardwareInfo: Sendable {
    let modelIdentifier: String
    let cpuBrand: String
    let architecture: String
    let osVersion: String
    let isAppleSilicon: Bool
    let isLaptop: Bool
    let hasBuiltInKeyboard: Bool
    let accelerometerPresent: Bool

    static func detect() -> HardwareInfo {
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return HardwareInfo(
            modelIdentifier: sysctlString("hw.model") ?? "Unknown",
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            architecture: machine,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            isAppleSilicon: machine == "arm64",
            isLaptop: hasInternalBattery(),
            hasBuiltInKeyboard: hasBuiltInKeyboard(),
            accelerometerPresent: HIDAccelerometer.isPresent()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    private static func hasBuiltInKeyboard() -> Bool {
        let matching: [String: Any] = ["IOProviderClass": "IOHIDDevice",
                                       "IOPropertyMatch": ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Built-In": true]]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }
}
