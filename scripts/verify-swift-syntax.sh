#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
find "$ROOT/Swift" -maxdepth 1 -name '*.swift' -print0 | xargs -0 swiftc -frontend -parse
echo "Swift syntax parse passed. (This is not an iOS SDK type-check or Xcode build.)"
