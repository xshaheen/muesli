#!/usr/bin/env bash
set -euo pipefail

if command -v imla-cli >/dev/null 2>&1; then
  command -v imla-cli
  exit 0
fi

if [[ -x "/Applications/Imla.app/Contents/MacOS/imla-cli" ]]; then
  echo "/Applications/Imla.app/Contents/MacOS/imla-cli"
  exit 0
fi

if [[ -x "native/ImlaNative/.build/debug/imla-cli" ]]; then
  echo "$(pwd)/native/ImlaNative/.build/debug/imla-cli"
  exit 0
fi

if [[ -x "native/ImlaNative/.build/release/imla-cli" ]]; then
  echo "$(pwd)/native/ImlaNative/.build/release/imla-cli"
  exit 0
fi

exit 1
