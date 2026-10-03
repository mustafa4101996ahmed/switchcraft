// Accelerometer access ported to native Swift from the approach documented in
// olvvier/apple-silicon-accelerometer (MIT License, Copyright (c) 2026 olvvier).
// See LICENSES/apple-silicon-accelerometer-MIT.txt.

import Foundation
import IOKit
import IOKit.hid
import SwitchcraftCore

/// Streams the Apple Silicon SPU accelerometer (AppleSPUHIDDevice, vendor page 0xFF00, usage 3).
///
/// Verified on MacBook Air M5 (Mac17,3), macOS 27.0: a normal user can open the device and it
/// streams ~800 Hz. No root, no helper. Reports are 22 bytes, X/Y/Z int32 little-endian at
/// offsets 6/10/14, divided by 65536 for g. The actual rate is measured, never assumed.
final class HIDAccelerometer: AccelerometerService, @unchecked Sendable {
    static let vendorUsagePage = 0xFF00
    static let accelerometerUsage = 3
    static let reportLength = 22
    static let dataOffset = 6
    static let scale: Float = 65536

    let ring = SampleRing(capacity: 4096)
    /// Called on the sensor thread.
    var onStateChange: (@Sendable (SensorState, String?) -> Void)? {
        get { lock.withLock { stateHandler } }
        set { lock.withLock { stateHandler = newValue } }
    }

    private let lock = UnfairLock()
    private var stateHandler: (@Sendable (SensorState, String?) -> Void)?
    private var currentState: SensorState = .stopped
    private var currentMessage: String?
    private var rate = 0.0
    private var reports = 0
    private var minimumFloor = 0.0002
    private var runLoop: CFRunLoop?
    private var finished: DispatchSemaphore?

    // Sensor-thread confined.
    private var filter = ImpactFilter()
    private var filterRateAdapted = false
    private var rateWindowStart = 0.0
    private var rateWindowCount = 0
    private var reportsAtLastCheck = 0
    private var stalled = false

    var state: SensorState { lock.withLock { currentState } }
    var message: String? { lock.withLock { currentMessage } }
    var measuredSampleRate: Double { lock.withLock { rate } }
    var totalReports: Int { lock.withLock { reports } }

    func setMinimumNoiseFloor(_ value: Double) { lock.withLock { minimumFloor = value } }

    /// IORegistry check; needs no permission and opens nothing.
    static func isPresent() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var found = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let page = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsagePageKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsageKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            if page == vendorUsagePage && usage == accelerometerUsage { found = true }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found
    }

    func start() {
        stop()
        let done = DispatchSemaphore(value: 0)
        lock.withLock { finished = done }
        let thread = Thread { [weak self] in
            self?.threadMain()
            done.signal()
        }
        thread.name = "com.switchcraft.sensor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops streaming and waits (≤ 1 s) for the sensor thread to tear down.
    func stop() {
        let (loop, done) = lock.withLock { (runLoop, finished) }
        guard let done else { return }
        if let loop { CFRunLoopStop(loop) }
        if done.wait(timeout: .now() + 1) == .timedOut {
            Log.sensor.error("Sensor thread did not stop within 1 s")
        }
        lock.withLock { finished = nil }
        setState(.stopped, nil)
    }

    private func setState(_ state: SensorState, _ message: String?) {
        let handler = lock.withLock { () -> (@Sendable (SensorState, String?) -> Void)? in
            guard currentState != state || currentMessage != message else { return nil }
            currentState = state
            currentMessage = message
            return stateHandler
        }
        handler?(state, message)
    }

    private func threadMain() {
        guard Self.isPresent() else {
            setState(.unsupported, "No compatible accelerometer (AppleSPUHIDDevice, page 0xFF00 usage 3).")
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [kIOHIDPrimaryUsagePageKey: Self.vendorUsagePage,
                                       kIOHIDPrimaryUsageKey: Self.accelerometerUsage,
                                       kIOHIDTransportKey: "SPU"]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            setState(.permissionRequired, "The accelerometer exists but couldn't be opened (IOReturn \(Self.hex(openResult))).")
            return
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard !devices.isEmpty else {
            setState(.permissionRequired, "The accelerometer is listed in IORegistry but IOHIDManager returned no device.")
            return
        }

        let loop = RunLoop.current.getCFRunLoop()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        resetThreadState()
        for device in devices {
            // Wake the sensor. On the tested Mac these succeed without root when set on the HID
            // device (setting them on the AppleSPUHIDDriver service needs root and is skipped).
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
                if !IOHIDDeviceSetProperty(device, key as CFString, value as CFNumber) {
                    Log.sensor.notice("IOHIDDeviceSetProperty \(key, privacy: .public) was refused")
                }
            }
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, 4096, hidReportCallback,
                                                                Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
        }
        lock.withLock { runLoop = loop }
        Log.helper.info("Privileged helper not required: direct IOKit HID access to the accelerometer succeeded")

        let watchdog = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1.5, 1.0, 0, 0) { [weak self] _ in
            self?.checkHealth(devices: devices)
        }
        CFRunLoopAddTimer(loop, watchdog, .defaultMode)

        CFRunLoopRun()

        CFRunLoopTimerInvalidate(watchdog)
        for device in devices {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, 4096, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
        }
        lock.withLock { runLoop = nil }
    }

    private func resetThreadState() {
        filter = ImpactFilter(minimumFloor: lock.withLock { minimumFloor })
        filterRateAdapted = false
        rateWindowStart = 0
        rateWindowCount = 0
        reportsAtLastCheck = 0
        stalled = false
        ring.reset()
        lock.withLock {
            reports = 0
            rate = 0
        }
    }

    /// Runs on the sensor thread once a second.
    private func checkHealth(devices: Set<IOHIDDevice>) {
        let total = totalReports
        defer { reportsAtLastCheck = total }
        guard total == reportsAtLastCheck else { return }
        stalled = true
        if total == 0 {
            setState(.permissionRequired, "The accelerometer opened but delivered no data.")
        } else {
            setState(.permissionRequired, "The accelerometer stopped delivering data; re-waking it.")
            lock.withLock { rate = 0 }
        }
        for device in devices {
            IOHIDDeviceSetProperty(device, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IOHIDDeviceSetProperty(device, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
        }
    }

    /// Runs on the sensor thread for every HID report.
    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int, timestamp: UInt64) {
        guard length == Self.reportLength else { return }
        let raw = UnsafeRawPointer(report)
        func axis(_ index: Int) -> Float {
            Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: Self.dataOffset + 4 * index, as: Int32.self))) / Self.scale
        }
        let time = timestamp != 0 ? MonotonicClock.seconds(fromTicks: timestamp) : MonotonicClock.now()
        ring.append(filter.process(AccelSample(time: time, x: axis(0), y: axis(1), z: axis(2))))

        let count = lock.withLock { () -> Int in
            reports += 1
            return reports
        }
        if count == 1 || stalled {
            stalled = false
            setState(.supported, nil)
            rateWindowStart = time
            rateWindowCount = 0
        }
        rateWindowCount += 1
        let elapsed = time - rateWindowStart
        if elapsed >= 1 {
            let measured = Double(rateWindowCount) / elapsed
            let floorSetting = lock.withLock { () -> Double in
                rate = measured
                return minimumFloor
            }
            filter.minimumFloor = floorSetting
            adaptFilter(to: measured)
            rateWindowStart = time
            rateWindowCount = 0
        }
    }

    /// The high-pass is designed for ~800 Hz; redesign it once if this Mac reports differently.
    private func adaptFilter(to measured: Double) {
        guard !filterRateAdapted, measured > 20, abs(measured - filter.sampleRate) / filter.sampleRate > 0.2 else { return }
        filterRateAdapted = true
        let cutoff = min(ImpactFilter.defaultCutoff, measured * 0.2)
        filter = ImpactFilter(sampleRate: measured, cutoff: cutoff, initialFloor: filter.noiseFloor,
                              minimumFloor: filter.minimumFloor)
        Log.sensor.notice("Sensor runs at \(measured, format: .fixed(precision: 0)) Hz; high-pass redesigned at \(cutoff, format: .fixed(precision: 0)) Hz")
    }

    static func hex(_ code: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }
}

private func hidReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                               type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                               reportLength: CFIndex, timeStamp: UInt64) {
    guard let context, result == kIOReturnSuccess else { return }
    Unmanaged<HIDAccelerometer>.fromOpaque(context).takeUnretainedValue()
        .handleReport(report, length: reportLength, timestamp: timeStamp)
}
