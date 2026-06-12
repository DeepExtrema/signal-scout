#!/bin/zsh
# Build (if needed) and run the WiFi Geiger Counter.
# Usage: ./find.sh <SSID>
set -e
cd "$(dirname "$0")"
if [[ $# -lt 1 ]]; then
  echo "Usage: ./find.sh <SSID>"
  exit 1
fi
if [[ geiger.swift -nt geiger || ! -x geiger ]]; then
  echo "Compiling…"
  swiftc -O geiger.swift -o geiger
fi
exec ./geiger "$1"
