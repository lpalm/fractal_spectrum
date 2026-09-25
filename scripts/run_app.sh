#!/bin/zsh
# Builds build/Spectrum.app and opens it, first quitting a running copy the normal way, so that an
# export in progress is asked about and a recording is saved (killing the app while it encodes once
# panicked the kernel).
set -euo pipefail
cd ${0:A:h:h}
./scripts/build_app.sh
if pgrep -xq Spectrum; then
  osascript -e 'tell application id "com.lpalm.spectrum" to quit'
  while pgrep -xq Spectrum; do sleep 0.2; done
fi
open build/Spectrum.app
