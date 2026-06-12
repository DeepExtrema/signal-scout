#!/bin/zsh
# Build (if needed) and run Signal Scout.
set -e
cd "$(dirname "$0")"
if [[ geiger.swift -nt geiger || ! -x geiger ]]; then
  echo "Compiling…"
  swiftc -O geiger.swift -o geiger
fi
exec ./geiger
