import Darwin

/// The single timebase used everywhere: seconds of host uptime on the mach absolute clock.
///
/// - HID report timestamps arrive as mach ticks.
/// - `CGEvent.timestamp` is nanoseconds on the same clock (verified on M5 / macOS 27: ratio = timebase).
/// - CoreAudio `mHostTime` is mach ticks.
/// A `Double` holds ~1e-10 s resolution at realistic uptimes, so seconds are precise enough.
public enum MonotonicClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    public static func now() -> Double { seconds(fromTicks: mach_absolute_time()) }

    public static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom / 1e9
    }

    public static func seconds(fromNanoseconds ns: UInt64) -> Double { Double(ns) / 1e9 }
}
