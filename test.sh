#!/bin/zsh
# Runs the test suite. Needs only the Swift toolchain, same as build.sh.
set -e
cd "$(dirname "$0")"

BIN="$(mktemp -d)/tests"
# Every source except main.swift, which owns the app's entry point.
SOURCES=(Sources/*.swift)
SOURCES=("${SOURCES[@]:#Sources/main.swift}")

swiftc "${SOURCES[@]}" Tests/main.swift \
  -o "$BIN" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI

"$BIN"
