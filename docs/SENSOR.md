# Accelerometer (SPU) access

Switchcraft reads the undocumented MEMS accelerometer that the Sensor Processing Unit (SPU)
exposes on Apple Silicon MacBooks. The approach comes from
[olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)
(MIT, see `LICENSES/`), re-implemented natively in Swift. No Python code is used.

## What the device looks like

| Property | Value |
|---|---|
| IORegistry class | `AppleSPUHIDDevice` (driver `AppleSPUHIDDriver`) |
| Transport | `SPU` |
| Usage page / usage | `0xFF00` / `3` (accelerometer); `9` is the gyroscope |
| Report length | 22 bytes |
| Payload | X, Y, Z as little-endian `Int32` at byte offsets 6, 10, 14 |
| Scale | raw ÷ 65536 = g |
| Timestamp | `IOHIDDeviceRegisterInputReportWithTimeStampCallback`, mach ticks |

## Measured on the development machine

MacBook Air M5 (`Mac17,3`), macOS 27.0 (26A428), 16 GB:

| Finding | Result |
|---|---|
| Device present | yes, alongside gyro, ALS, lid angle, `devmotion6`, `cma`, `wakehint` |
| `IOHIDManagerOpen` as a normal user | `kIOReturnSuccess` |
| Root required | **no** |
| Wake properties | `SensorPropertyReportingState`, `SensorPropertyPowerState`, `ReportInterval` written to the `AppleSPUHIDDriver` service with `IORegistryEntrySetCFProperty`, as a normal user. Without them the sensor delivers nothing after a restart |
| Callback rate | **801.6 Hz** measured (the `ReportInterval` value doesn't change it) |
| HID timestamp → callback | p50 0.43 ms, p99 1.1 ms |
| Gravity at rest | \|a\| ≈ 1.008 g |
| Noise floor (25 Hz high-pass) | ≈ 0.6 mg median |
| Keystroke impulse peak | ≈ 7 mg (p10) / 12 mg (p50) / 26 mg (p90) / 55 mg (max) |
| Trackpad click | ≈ 2 mg |
| Desk bump / laptop moved | up to 880 mg |

The reference project runs with `sudo` and writes those wake properties to the
`AppleSPUHIDDriver` **service** (`IORegistryEntrySetCFProperty`). On macOS 27 that same write
succeeds as a normal user, and it's required: after a restart the sensor delivers nothing until it
happens, and it then keeps streaming until the next restart. Writing the properties to the **HID
device** with `IOHIDDeviceSetProperty` returns success but never reaches the driver. Switchcraft 1.0
only did the latter and seemed to work because the sensor was already awake; after a restart on
8 Oct 2026 it delivered 0 reports for 8 hours until the driver write was added. One more trap: an
`IOHIDDevice` created with `IOHIDDeviceCreate` gets released when it goes out of scope, which
silently stops all callbacks. The first probe hit exactly this and reported 0 samples.

**Conclusion: no privileged helper is needed on this hardware.** Switchcraft never runs anything as
root and ships no LaunchDaemon. If a future macOS or another Mac refuses the open,
Switchcraft reports `SENSOR_PERMISSION_REQUIRED` with the IOReturn code and falls back to Fixed
velocity. See `TROUBLESHOOTING.md`.

## Keyboard timing relative to the sensor

`CGEvent.timestamp` is **nanoseconds on the mach clock** (ratio to `mach_absolute_time` = the
timebase, 125/3 on Apple Silicon). The event tap receives events ~0.15 ms after their timestamp.
Everything in Switchcraft is converted to seconds on this one clock (`MonotonicClock`).

Aligning ~40 isolated keystrokes on the key-event timestamp (median envelope):

```
 -12 ms  finger strike begins          ▁▂▃
  -5 ms  strike peak                   ▅▅
   0     key event (switch registers)  ▄
 +7.5 …+10 ms  bottom-out peak         ▇▇▆
 +15 ms  decayed                       ▃
```

So the useful window is about −15 ms … +10 ms around the key event. Capturing the bottom-out
peak costs latency, so the trailing edge (`postMs`) is a setting:

| postMs | peak captured vs. unlimited window (median) | log-correlation with unlimited peak |
|---|---|---|
| 0 | 0.75 | 0.84 |
| 4 | 0.83 | 0.90 |
| **8 (default)** | **0.99** | **0.95** |
| 10 | 1.00 | 0.97 |
| 12 | 1.00 | 0.99 |

## Re-running the measurements

```sh
xcrun swiftc -O Scripts/sensor-probe.swift -o build/sensor-probe && build/sensor-probe 3
```

The probe enumerates every SPU HID service, opens the accelerometer, wakes it, streams for N
seconds and prints the measured rate plus parsed samples. It never touches the keyboard.

In the app, Diagnostics → **Run Sensor Test** does the same from inside Switchcraft, and the
live graph shows key events, correlation windows and detected impacts.

## Validation still needed on other hardware

Only one Mac was available. Untested and therefore unknown:

- M1–M4 MacBook Air/Pro (the reference reports M2+ and was tested on an M3 Pro).
- Whether older macOS versions (14, 15) also allow non-root access.
- Desktop Macs: no SPU accelerometer is expected → `UNSUPPORTED_SENSOR`.
- Intel Macs: not supported (the target is arm64-only).
