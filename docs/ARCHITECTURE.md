# Architecture

Two targets plus tests:

- **SwitchcraftCore** (framework): pure logic, no UI, no hardware. Models, key classification,
  sample ring, impact DSP, velocity mapping, calibration, sound-pack parsing/validation,
  settings, and the realtime pipeline. Everything here is unit-tested.
- **Switchcraft** (app): hardware and UI. Keyboard tap, HID accelerometer, audio engine,
  sound-pack library, permissions, system events, SwiftUI views.
- **SwitchcraftTests**: Swift Testing suites against SwitchcraftCore, using mocks for the three
  hardware protocols (`AccelerometerService`, `KeyEventSource`, `SoundOutput`).

```
SwitchcraftCore/
  Models/            KeyGroup, VelocityLayer, VelocityMode, SensorState, AccelSample, KeyEvent
  Keyboard/          KeyClassifier (key code → group)
  Sensors/           SampleRing (preallocated ring, one writer, many readers)
  ImpactDetection/   ImpactFilter, ImpactAnalyzer, VelocityMapper, LayerBlend, Calibration, SyntheticSignals
  SoundPacks/        SoundPackManifest, SoundPack (+ fallback resolution), SoundPackLoader (validation)
  Settings/          SettingsStore (UserDefaults, JSON per key)
  Pipeline/          Services (protocols), PipelineConfig, PipelineStats, TypingPipeline
  Utilities/         Log (os.Logger), MonotonicClock, UnfairLock
Switchcraft/
  Application/       SwitchcraftApp, AppModel (composition root), WindowCoordinator, SystemMonitor
  MenuBar/           MenuBarView
  Preferences/       Settings tabs
  Keyboard/          KeyboardMonitor (listen-only CGEventTap)
  Sensors/           HIDAccelerometer, HardwareInfo
  Audio/             SoundEngine (AVAudioEngine host), VoiceMixer (render callback), SampleBank
  SoundPacks/        SoundPackLibrary (bundled + user packs, import)
  Permissions/       PermissionsService
  Diagnostics/       DiagnosticsView, ImpactGraphView, DiagnosticsReport
  Onboarding/        OnboardingView, CalibrationView (+ CalibrationSession)
```

## Threads

| Thread / queue | Work | Never does |
|---|---|---|
| `com.switchcraft.keyboard` (CFRunLoop) | CGEventTap callback: read key code + timestamp, build `KeyEvent`, hand off | DSP, audio, UI |
| `com.switchcraft.sensor` (CFRunLoop) | HID report callback ~800 Hz: parse, high-pass, magnitude, noise floor, append to ring | allocation, UI |
| `com.switchcraft.impact` (serial, user-interactive) | wait for window, analyze, map velocity, call `SoundEngine.play` | UI, disk, JSON |
| CoreAudio IO thread | `VoiceMixer.render`: start queued voices, mix, limiter | locks (only `tryLock`), allocation, ObjC |
| Main actor | SwiftUI, settings, pack loading orchestration, system notifications | anything per-sample |

Sample decoding runs on a detached task when a pack is selected. The UI reads diagnostics by
snapshot: text at 10 Hz, graph at ≤ 30 fps.

## Key press → sound

```
CGEventTap (listen-only)          HID callback (~800 Hz)
  key code, CGEvent ns timestamp     XYZ int32 → g, mach timestamp
        │                                  │ ImpactFilter: HPF 25 Hz ×3 → |d| → noise floor
        ▼                                  ▼
  KeyEvent ──► TypingPipeline.handle ──► SampleRing (4096 samples ≈ 5 s)
                    │ (queue; > 32 pending → dropped + counted)
                    ▼
        wait until ring covers keyTime + post (bounded: post + 6 ms)
        ImpactAnalyzer.measure(window = [t − pre, t + post])
            peak, floor, magnitude = peak − floor − previous-impact tail
            outcome: detected / belowNoise / rejectedTooLarge / noData
        VelocityMapper: calibration anchors in log space → sensitivity/gain/gamma → min…max
                    ▼
        SoundEngine.play(group, velocity, keyTime)
            LayerBlend: two adjacent layers, linear gains (same hit → correlated)
            same random hit in both layers, ±0.5 % speed, velocity-scaled loudness
        key-up → SoundEngine.playRelease(group, velocity of that key's press)
                    ▼
            key code → the key's own recording + constant-power pan by keyboard position (KeyLayout)
        VoiceMixer queue (tryLock) → 48 voices → master gain → peak limiter
            → AVAudioUnitReverb (small room, 0–20 % wet, bypassed at 0) → output
```

## Alert-beep suppression

`AlertBeepSuppressor` gets a ping from the keyboard thread on every press (one lock, no work).
The first press of a burst hops to the main thread and sets the macOS alert volume to 0 through a
pre-compiled, pre-warmed AppleScript `set volume` (~3 ms, no Automation permission because it
runs in-process). A 250 ms timer restores the saved level once a second has passed without a
press. The saved level lives in UserDefaults until restored, so quit and crash paths restore it
too. It's inactive while Switchcraft is disabled or an excluded app is in front.

## Concurrency rules

- The keyboard, sensor and impact paths share data only through `SampleRing`, `Locked<T>` and
  `PipelineStats`. All are guarded by `os_unfair_lock` with critical sections of tens of
  nanoseconds, and the render thread only ever calls `tryLock`.
- `PipelineConfig` is an immutable snapshot rebuilt by `AppModel` whenever a setting changes.
  The realtime path never reads `SettingsStore`.
- `SampleBank` swaps are atomic: the old bank is retired for 1 s so a render cycle in flight
  can never read freed memory.
- Swift 6 language mode with complete strict concurrency, zero warnings.

## Lifecycle and resilience

| Event | Handling |
|---|---|
| Audio device change (headphones, Bluetooth) | `AVAudioEngineConfigurationChange` → restart engine. Samples are stored at 48 kHz, so nothing is re-decoded. |
| Sleep | sensor stopped |
| Wake | after 1.5 s: restart audio, re-check permission, restart keyboard tap and sensor |
| Fast User Switching | session inactive → stop tap, sensor and audio. Active again → resume. |
| Sensor stall | 1 s watchdog: re-wake the device; state shows `SENSOR_PERMISSION_REQUIRED` with a message until data returns |
| Permission revoked / granted | polled every 2 s; the tap stops or starts without relaunch |
| Event tap disabled by the system | re-enabled in the callback |
| Pack deleted / invalid | falls back to the default pack; the error shows in Settings |
| Unsupported Mac | `UNSUPPORTED_SENSOR`; accelerometer mode plays at Fixed velocity |

## Design decisions

- **No privileged helper.** Measured: direct HID access works as a normal user (docs/SENSOR.md).
  Adding a root daemon without a need would only add attack surface.
- **AppKit-managed windows** for Settings/Diagnostics/Onboarding: on macOS 14, SwiftUI `Window`
  scenes can't be kept from opening at launch.
- **Own mixer instead of `AVAudioPlayerNode`s.** One render callback gives exact voice control,
  continuous crossfades, a limiter, voice stealing and key→render latency measurement, with
  no per-press allocation.
- **Velocity is measured, not inferred from timing.** Without a readable sensor the app says
  so and uses Fixed velocity rather than faking dynamics.
