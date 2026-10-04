#!/bin/zsh
# Builds and runs Scripts/make-keystroke-chart/main.swift against the real SwitchcraftCore DSP sources.
set -euo pipefail
cd "$(dirname "$0")/.."
C=SwitchcraftCore
xcrun swiftc -O -module-name SwitchcraftChart Scripts/make-keystroke-chart/main.swift \
  $C/Models/Models.swift $C/Keyboard/KeyClassifier.swift $C/Sensors/SampleRing.swift $C/Utilities/UnfairLock.swift \
  $C/Utilities/MonotonicClock.swift $C/Utilities/Log.swift $C/ImpactDetection/*.swift -o build/make-keystroke-chart
build/make-keystroke-chart docs/images/keystroke.svg
