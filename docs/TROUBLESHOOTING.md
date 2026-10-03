# Troubleshooting

Start with the menu bar → **Diagnostics…**. Every value below is visible there, and
**Copy Diagnostics** produces a text report with no typed text.

## No sound when typing

1. **Input Monitoring.** The menu-bar icon is a ⚠️ triangle while permission is missing.
   System Settings › Privacy & Security › Input Monitoring → turn on Switchcraft. The app notices
   within 2 seconds. If Diagnostics still shows *Monitor: Stopped*, quit and reopen Switchcraft.
2. **After rebuilding the app** the switch can look on but no longer apply. Local builds are
   ad-hoc signed and macOS ties the permission to the exact binary. Select Switchcraft in the
   Input Monitoring list, remove it with **−**, then add `/Applications/Switchcraft.app` again with
   **+** (or run `tccutil reset ListenEvent com.switchcraft.app` and re-grant).
3. **Enabled?** The switch at the top of the menu-bar panel.
4. **Excluded app or microphone mute.** Settings › Exclusions. Diagnostics shows *Muted by
   exclusions* counting up.
5. **Secure input.** Password fields (and some terminals with "Secure Keyboard Entry") hide
   keystrokes from every app. Diagnostics › Keyboard › *Secure input: Active*. Nothing to fix:
   it's macOS protecting you.
6. **Audio.** Diagnostics › Audio › *Engine*. Try **Actions › Restart Audio Engine**. Check
   the output device and volume.

## Everything sounds the same strength

- Velocity Detection must be **Accelerometer** (menu bar).
- Diagnostics › Accelerometer › *Readable* should say `SUPPORTED` with a sample rate around
  800 Hz. Watch the live graph: each key press should draw a green line with a red circle
  (detected impact) shortly after it.
- Run **Calibrate Typing Force…**. The factory calibration comes from one MacBook Air and
  your typing may differ.
- Raise **Sensitivity**, or open Settings › Typing Force › Advanced and lower *Detection
  threshold*.
- A soft surface (lap, sofa, thick mat) absorbs the impulse. A desk works best.

## Sensor states

| State | Meaning | What to do |
|---|---|---|
| `SUPPORTED` | Streaming. | — |
| `SENSOR_PERMISSION_REQUIRED` | The device exists but opening it failed, or it delivers no data. The message includes the IOReturn code. | Restart Sensor. Run `build/sensor-probe` (docs/SENSOR.md) to check outside the app. If the probe also fails, this macOS/Mac blocks non-root access: Switchcraft keeps working with Fixed velocity. |
| `UNSUPPORTED_SENSOR` | No `AppleSPUHIDDevice` accelerometer (desktop Mac, Intel, or older Apple Silicon). | Use Fixed or Simulated velocity. |
| `SIMULATION_MODE` | Velocity Detection is set to Simulated. | — |

Switchcraft never asks you to run it with `sudo` and never installs a root helper. On the tested
hardware none is needed.

## Apps still beep when I press a key

Settings › General › *Silence the “invalid key” beep while typing* must be on. It works by
lowering the macOS alert volume during a typing burst. The very first key of a burst can
occasionally beat it, because the app beeps within milliseconds. Your alert volume comes back about
a second after you stop typing, when Switchcraft quits, and on the next launch after a crash.
If alerts ever stay silent, System Settings › Sound › *Alert volume* resets them.

## Sounds are late

- Diagnostics › Audio › *Estimated latency* is measured from the hardware key event to the
  audio render cycle, plus the device latency CoreAudio reports.
- In Accelerometer mode Switchcraft waits until the chassis bottom-out impulse has been captured:
  Advanced › *Correlation window: after key* (default 8 ms). Lower values react faster with less
  accurate velocity. 0 ms uses only the finger-strike impulse.
- Bluetooth headphones add 100–250 ms of their own. Use built-in speakers or wired headphones.

## Clicks, crackles, distortion

- Lower the volume. The limiter (Diagnostics › Audio › *Limiter*) prevents clipping but
  heavy limiting sounds squashed.
- *Dropped events* or *voices stolen* rising means more than 48 voices at once, which needs
  unusually long samples. Shorten custom pack samples.

## Launch at Login doesn't stick

macOS may require approval: System Settings › General › Login Items › allow Switchcraft.
Login items work best when the app lives in `/Applications` (`Scripts/install.sh`).

## A custom pack doesn't import

Settings › Sound shows the reason (see docs/SOUNDPACK_FORMAT.md › Validation). Per-sample
problems appear under *Pack warnings*.

## Logs

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "com.switchcraft.app"'
```

Categories: `app`, `keyboard`, `sensor`, `impact`, `audio`, `soundpack`, `helper`, `permissions`.
Logs never contain typed characters.
