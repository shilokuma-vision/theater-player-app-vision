#!/bin/bash
set -euo pipefail

# App Review の担当者に渡すサンプルの動画を作る（Tools/ReviewSample/README.md）。
#
#   Tools/ReviewSample/make-review-sample.sh [出力のパス]
#
# 既定の出力は .build/review-sample/TheaterPlayer-Sample.mov（git には入らない）。M4 Max で 2 分ほど

root="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
output="${1:-$root/.build/review-sample/TheaterPlayer-Sample.mov}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

xcrun swiftc -O -swift-version 6 "$root"/Tools/ReviewSample/Sources/*.swift -o "$build/make-review-sample"
mkdir -p "$(dirname "$output")"
"$build/make-review-sample" "$output"
