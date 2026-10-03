# Switchcraft sound pack format (version 1)

A pack is a folder whose name ends in `.switchcraft`:

```
MyPack.switchcraft/
├── manifest.json
└── sounds/
    ├── alpha/
    │   ├── soft/    1.wav 2.wav 3.wav
    │   ├── medium/  …
    │   ├── hard/    …
    │   ├── slam/    …
    │   └── release/ up.wav        (optional key-up sound)
    ├── space/
    ├── enter/
    ├── backspace/
    ├── modifier/
    └── other/
```

## manifest.json

```json
{
  "formatVersion": 1,
  "id": "my-keyboard",
  "name": "My Keyboard",
  "author": "You",
  "description": "Recorded on a 65% board with lubed linears.",
  "category": "Linear",
  "credits": "Recorded by You, CC0.",
  "gain": 1.0,
  "samples": {
    "alpha": {
      "soft":   ["sounds/alpha/soft/1.wav", "sounds/alpha/soft/2.wav"],
      "medium": ["sounds/alpha/medium/1.wav"],
      "hard":   ["sounds/alpha/hard/1.wav"],
      "slam":   ["sounds/alpha/slam/1.wav"],
      "release": ["sounds/alpha/release/1.wav"]
    },
    "space": { "medium": ["sounds/space/1.wav"] }
  }
}
```

| Key | Required | Meaning |
|---|---|---|
| `formatVersion` | yes | Must be `1`. |
| `name` | yes | Display name (non-empty). |
| `id` | no | Stable identifier. Defaults to the folder name. Imported packs get a `user.` prefix. |
| `author`, `description`, `category`, `credits` | no | Shown in Settings › Sound › About this pack. |
| `gain` | no | Linear gain for every sample, 0–4 (default 1). |
| `deriveVelocityLayers` | no | `true`: every press recording is one full-force hit and Switchcraft generates soft/medium/hard/slam from it at load time. Put the files under any layer (normally `hard`). Easiest way to make a pack from your own recordings. |
| `samples` | no | group → layer → list of paths relative to the pack. **If omitted, `sounds/<group>/<layer>/*` is scanned.** |

### Groups

`alpha`, `number`, `space`, `enter`, `backspace`, `tab`, `modifier`, `arrow`, `function`,
`escape`, `punctuation`, `other`. Groups are physical key positions, so they don't change
with the keyboard layout.

### Velocity layers

`soft`, `medium`, `hard`, `slam`. Layer centres sit at velocity 0.125 / 0.375 / 0.625 / 0.875.
Playback **crossfades** the two layers around the current velocity (linearly), so a press at
0.37 is mostly `medium` with a little `soft`. Record each layer with a genuinely different
strike: timbre should change, not just level. Switchcraft also scales loudness by velocity.

### Generated layers (`"deriveVelocityLayers": true`)

Record each key once, at a normal-to-firm strike, and let Switchcraft build the layers:

| Layer | Processing of the hit |
|---|---|
| soft | 2 × 2800 Hz low-pass, −6 dB, 0.8 ms rounded onset |
| medium | 6500 Hz low-pass, −2.5 dB |
| hard | the recording itself |
| slam | +5 dB low shelf at 180 Hz, +2 dB into tanh saturation (never exceeds full scale) |

All bundled packs use this.

### Key-up (`release`)

An optional sixth layer name, `release`, holds the switch's upstroke. It's played when the key
is lifted, at a level following the matching press's velocity. Lookup follows the group fallback
chain (`enter → space → other → alpha`). A pack with no release recordings simply has silent
key-ups. Release files alone don't make a valid pack: press samples are required.

### Multiple samples

Every list can hold several files. Each physical key always plays the same file of its group
(chosen from its key code), the way every key on a real board has its own sound; Preview picks
at random. Keep the lists of a group in the same order across layers: the same index is used for
both crossfaded layers, so entry N of every list should be the same physical hit. The optional
random variation adds only ±0.5 % speed and ±0.5 dB.

Mono and stereo files are both fine. Mono files are placed in the stereo field by key position;
stereo files keep their own image and are balanced toward the key's side.

Crossfades are **linear** (gains sum to 1) because layers are normally the same hit at
different intensities. Layers recorded as separate hits still work, but sound best when their
transients line up at sample 0.

## Audio files

- `.wav`, `.aif`/`.aiff`, `.caf`. Any sample rate or channel count: files are decoded once,
  downmixed to mono and resampled to 48 kHz when the pack is selected.
- Keep each file short (keyboard sounds are 80–350 ms). Files are truncated at 2 s; larger than
  10 MB is rejected.
- Trim leading silence: the transient should start within the first millisecond, or latency
  suffers.

## Fallbacks

Missing recordings never cause silence:

1. Same group, nearest recorded layer (ties prefer the softer layer).
2. The group's fallback chain, e.g. `backspace → enter → other → alpha`,
   `number → alpha`, `space → enter → other → alpha`.
3. Any group with recordings.

A pack with only `sounds/alpha/medium/1.wav` is valid: every key plays that file.

## Validation

On import (and every launch) Switchcraft rejects a pack when:

- `manifest.json` is missing or not valid JSON,
- `formatVersion` isn't 1, `name` is empty, or `gain` is outside 0–4,
- no usable sample remains.

Individual samples are skipped with a warning (shown in Settings › Sound) when the path is
absolute, escapes the pack folder (`..`, symlinks), the file is missing, too large or of an
unsupported type, or the group/layer name is unknown.

## Installing

- Settings › Sound › **Import Sound Pack…**, or drag the `.switchcraft` folder onto the pack list.
- Or copy it into `~/Library/Application Support/Switchcraft/SoundPacks/` and choose
  **More › Reload Packs**.

The bundled packs are produced by `Scripts/build-sound-packs.swift`. It's also a worked example
of cutting a pack from three kinds of source: per-key files (kbsim), a sprite with per-key
offsets whose slices hold press + release (mechvibes), and continuous recordings segmented by
onset detection (Freesound):

```sh
Scripts/fetch-sound-sources.sh build/sources
xcrun swiftc -O Scripts/build-sound-packs.swift -o build/build-sound-packs
build/build-sound-packs build/sources SoundPacks
```
