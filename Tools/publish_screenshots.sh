#!/bin/bash
set -euo pipefail

# 手元の Mac で撮った App Store 用のスクリーンショットを、ドラフトのリリースに添付する。
# App Store Connect への反映は、ワークフロー（Screenshots/App Store）が行う。
#
#   Tools/publish_screenshots.sh <タグ名> [表示サイズ]
#
# GitHub Actions の macOS ランナー（仮想マシン）の Simulator では、映画館（Immersive Space）を描けない（LEARNINGS.md）。
# そのため、映画館を写すスクリーンショットは手元の Mac で撮り（Tools/capture_screenshots.sh）、このスクリプトで
# build/screenshots/<表示サイズ>/<言語>/*.png を screenshots-<表示サイズ>.zip にまとめて、<タグ名> のドラフトのリリースに添付する
# （無ければドラフトで作る。同じ名前の添付は置き換える）。ドラフトは公開されず、リポジトリに書き込める人にだけ見える。
# 添付したら、release/** ブランチで、screenshots_release に <タグ名> を入れてワークフローを流す:
#
#   gh workflow run app-store-screenshots.yml --ref release/1.0.0 -f screenshots_release=<タグ名>
#
# 反映が済んだら、ドラフトのリリースは消してよい（タグはドラフトのあいだは作られない）。

TAG="${1:?タグ名（例: screenshots-1.0.0）を指定してください}"
DISPLAY_TYPE="${2:-APP_APPLE_VISION_PRO}"

TOOLS_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
cd "$TOOLS_DIR/.."
CONFIG="python3 $TOOLS_DIR/app_store_config.py"
SCREENSHOTS_DIR="${SCREENSHOTS_DIR:-$PWD/build/screenshots}"
SOURCE="$SCREENSHOTS_DIR/$DISPLAY_TYPE"

if [ ! -d "$SOURCE" ]; then
    echo "$SOURCE がありません。先に Tools/capture_screenshots.sh $DISPLAY_TYPE で撮ってください" >&2
    exit 1
fi

# 寸法・アルファ・枚数は反映の前にワークフローでも確かめるが、添付してから落ちると遠回りなので、ここでも確かめる
python3 "$TOOLS_DIR/verify_screenshots.py" \
    --directory "$SOURCE" \
    --sizes "$($CONFIG sizes "$DISPLAY_TYPE" | paste -sd, -)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/screenshots-$DISPLAY_TYPE.zip"
# zip の中は <言語>/<ファイル名>.png にする（ワークフローが build/screenshots/<表示サイズ>/ に展開する）
(cd "$SOURCE" && zip -q -r "$ARCHIVE" . -i '*.png')
echo "$(unzip -Z1 "$ARCHIVE" | wc -l | tr -d ' ') 枚を $(basename "$ARCHIVE") にまとめました（$(du -h "$ARCHIVE" | cut -f1)）"

if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ARCHIVE" --clobber
else
    gh release create "$TAG" "$ARCHIVE" \
        --draft \
        --title "App Store のスクリーンショット（$TAG）" \
        --notes "手元の Mac で撮った App Store 用のスクリーンショット。Screenshots/App Store を screenshots_release=$TAG で流すと反映する。反映が済んだら消してよい。"
fi

echo "ドラフトのリリース $TAG に添付しました。release/** ブランチで次を流してください:"
echo "  gh workflow run app-store-screenshots.yml --ref <release/…> -f screenshots_release=$TAG"
