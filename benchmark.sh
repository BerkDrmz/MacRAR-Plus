#!/bin/zsh
set -e
cd "$(dirname "$0")"
mkdir -p artifacts/performance
sources=(Sources/*.swift)
sources=("${(@)sources:#Sources/main.swift}")
swiftc -O -target arm64-apple-macos13.0 -swift-version 5 -framework AppKit -framework UniformTypeIdentifiers -framework SwiftUI -framework Quartz "${sources[@]}" Tests/Performance/main.swift -o artifacts/performance/benchmark
artifacts/performance/benchmark "$PWD/artifacts/performance" | tee artifacts/performance/results.txt
