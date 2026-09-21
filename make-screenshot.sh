#!/bin/zsh
# Renders docs/screenshot.png from the real panel with sample agents, so the
# README image stays in step with the UI and contains nobody's real projects.
set -e
cd "$(dirname "$0")"
BIN="$(mktemp -d)/shot"
SOURCES=(Sources/*.swift)
SOURCES=("${SOURCES[@]:#Sources/main.swift}")
swiftc "${SOURCES[@]}" Tools/Screenshot/main.swift -o "$BIN" \
  -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework SwiftUI
"$BIN"
