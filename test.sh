#!/bin/zsh
set -e
cd "$(dirname "$0")"
rm -rf artifacts/fixtures
python3 Tests/create-fixtures.py
mkdir -p artifacts/test-bin
for engine in rar unrar 7zz; do ln -sf "$PWD/tools/$engine" "artifacts/test-bin/$engine"; done
sources=(Sources/*.swift)
sources=("${(@)sources:#Sources/main.swift}")
swiftc -target arm64-apple-macos13.0 -swift-version 5 -framework AppKit -framework UniformTypeIdentifiers -framework SwiftUI -framework Quartz "${sources[@]}" Tests/*.swift -o artifacts/test-bin/tests
MACRAR_LANG=tr artifacts/test-bin/tests "$PWD/artifacts/fixtures"
