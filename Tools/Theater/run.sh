#!/bin/bash
# Blender を画面なしで起動し、映画館のモデルのスクリプトを実行する（個人の設定・アドオンは読み込まない）。
# 使い方: Tools/Theater/run.sh <スクリプト（build_theater.py など）> [スクリプトに渡す引数...]
#   Blender の場所は BLENDER で変えられる（既定は /Applications/Blender.app）。Blender 5.2 で確かめている
set -euo pipefail
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/$1"
shift
"$BLENDER" -b --factory-startup --python-exit-code 1 --python "$script" -- "$@"
