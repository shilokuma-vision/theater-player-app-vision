#!/bin/bash
# scripts/build-ffmpeg.sh で作った FFmpeg.xcframework を zip にして、GitHub の Release（タグ ffmpeg-<版>-dav1d-<版>-<作り方のハッシュ>）に置く。
# Packages/TheaterMedia/Package.swift の binaryTarget(url:checksum:) がこの zip を取るので、clone した人・CI・AskHub のワーカーは FFmpeg を作らずにビルドできる。
# バイナリと一緒に、FFmpeg の LGPL 2.1 の手続きとして、そのバイナリのソース（公式の配布物・当てたパッチ・作り方）を同じ Release に添付する。
#
# 使い方: scripts/publish-ffmpeg-release.sh [--publish]
#   既定は確かめるだけ: 作ったものが今のスクリプト・パッチ・Deployment Target のものかを確かめ、添付する物を
#   .build/ffmpeg-release/<タグ>/ に用意して、Package.swift に書く url と checksum を表示する。タグと Release は作らない
#   --publish  タグ（origin/develop の先頭）と Release を GitHub に作る（公開。誰でも見られる）。同じタグがあれば止める
#
# 先に scripts/build-ffmpeg.sh（引数なし。実機と Simulator の両方）を実行しておく。作業フォルダは FFMPEG_BUILD_DIR で変えられる
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="${FFMPEG_BUILD_DIR:-$root/.build/ffmpeg}"
vendor="$root/Packages/TheaterMedia/Vendor"
framework="$vendor/FFmpeg.xcframework"
stamp="$vendor/FFmpeg.stamp"

publish=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish)
      publish=1
      shift
      ;;
    *)
      echo "エラー: 知らない引数です（$1）" >&2
      exit 1
      ;;
  esac
done

step() {
  echo "==> $*"
}

origin_url="$(git -C "$root" remote get-url origin)"
repository="$(printf '%s\n' "$origin_url" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "エラー: origin（${origin_url}）から GitHub のリポジトリを決められません" >&2
  exit 1
fi

setting() {
  sed -n -E "s/^$2 *= *([^ ]*).*/\1/p" "$1" | head -n 1
}
ffmpeg_version="$(setting "$root/scripts/build-ffmpeg.sh" FFMPEG_VERSION)"
ffmpeg_sha="$(setting "$root/scripts/build-ffmpeg.sh" FFMPEG_SHA256)"
dav1d_version="$(setting "$root/scripts/build-ffmpeg.sh" DAV1D_VERSION)"
dav1d_sha="$(setting "$root/scripts/build-ffmpeg.sh" DAV1D_SHA256)"
deployment_target="$(setting "$root/Configs/Project.xcconfig" XROS_DEPLOYMENT_TARGET)"

# build-ffmpeg.sh と同じ式で、作り方（スクリプト・pkg-config・パッチ）のハッシュを出す
patches=("$root"/scripts/ffmpeg/patches/*.patch)
script_hash="$(cat "$root/scripts/build-ffmpeg.sh" "$root/scripts/ffmpeg/pkg-config" "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
expected="ffmpeg=$ffmpeg_version dav1d=$dav1d_version target=$deployment_target platforms=xros xrsimulator script=$script_hash"
if [[ ! -d "$framework" || ! -f "$stamp" ]]; then
  echo "エラー: ${framework#"$root/"} がありません。先に scripts/build-ffmpeg.sh を実行してください" >&2
  exit 1
fi
if [[ "$(cat "$stamp")" != "$expected" ]]; then
  echo "エラー: 作ったものが今のスクリプト・パッチ・Deployment Target のものではありません（実機と Simulator の両方を、dav1d を入れて作り直してください）" >&2
  echo "  作ったもの: $(cat "$stamp")" >&2
  echo "  今の作り方: $expected" >&2
  exit 1
fi

tag="ffmpeg-$ffmpeg_version-dav1d-$dav1d_version-${script_hash:0:8}"
staging="$root/.build/ffmpeg-release/$tag"
step "添付する物を用意する（${staging#"$root/"}）"
rm -rf "$staging"
mkdir -p "$staging"
# zip の中は FFmpeg.xcframework/ から始める（SwiftPM の binaryTarget の決まり）。
# 作り直しても checksum が変わらないよう、写しの時刻をそろえ、並びを決め、拡張属性を入れずに固める
# （Package.swift の checksum を先に PR で直し、公開した zip と食い違わないようにする）
copy="$staging/zip"
mkdir -p "$copy"
ditto --norsrc --noextattr --noqtn "$framework" "$copy/FFmpeg.xcframework"
TZ=UTC find "$copy/FFmpeg.xcframework" -exec touch -h -t 200001010000.00 {} +
(cd "$copy" && find FFmpeg.xcframework -print | LC_ALL=C sort | TZ=UTC zip -X -y -q -@ "$staging/FFmpeg.xcframework.zip")
rm -rf "$copy"
for pair in "ffmpeg-$ffmpeg_version.tar.xz=$ffmpeg_sha" "dav1d-$dav1d_version.tar.xz=$dav1d_sha"; do
  name="${pair%%=*}"
  file="$work/src/$name"
  if [[ ! -f "$file" ]] || ! echo "${pair#*=}  $file" | shasum -a 256 -c --status; then
    echo "エラー: ${file} が無いか、SHA-256 が scripts/build-ffmpeg.sh の値と一致しません（scripts/build-ffmpeg.sh を実行し直してください）" >&2
    exit 1
  fi
  cp "$file" "$staging/$name"
done
cat "${patches[@]}" > "$staging/ffmpeg-$ffmpeg_version-theater-player.diff"
cp "$root/scripts/build-ffmpeg.sh" "$staging/build-ffmpeg.sh"

checksum="$(cd "$root/Packages/TheaterMedia" && swift package compute-checksum "$staging/FFmpeg.xcframework.zip")"
url="https://github.com/$repository/releases/download/$tag/FFmpeg.xcframework.zip"

commit="$(git -C "$root" rev-parse --verify origin/develop)"
cat > "$staging/notes.md" <<EOF
TheaterPlayer が使う FFmpeg $ffmpeg_version（dav1d $dav1d_version を含む）の visionOS 向けのビルド（実機 xros・Simulator xrsimulator、Deployment Target $deployment_target）。
\`Packages/TheaterMedia/Package.swift\` の \`binaryTarget(url:checksum:)\` がこの \`FFmpeg.xcframework.zip\` を取ります。

- 作り方: 添付の \`build-ffmpeg.sh\`（このタグのコミットの \`scripts/build-ffmpeg.sh\`）。作り方のハッシュは \`$script_hash\`
- checksum（\`swift package compute-checksum\`）: \`$checksum\`

## ライセンス

FFmpeg は LGPL 2.1 以降の構成です（GPL・nonfree のコンポーネントは有効にしていません）。dav1d は BSD 2-Clause です。
LGPL の手続きとして、このバイナリのソースを添付します。

- \`ffmpeg-$ffmpeg_version.tar.xz\`・\`dav1d-$dav1d_version.tar.xz\`: 公式の配布物（SHA-256 は \`build-ffmpeg.sh\` に書いた値と同じ）
- \`ffmpeg-$ffmpeg_version-theater-player.diff\`: FFmpeg に当てたパッチ（\`scripts/ffmpeg/patches/*.patch\` をつないだもの）
- \`build-ffmpeg.sh\`: configure の指定を含む作り方
EOF

echo
echo "タグ: $tag（${commit:0:8}）"
echo "Package.swift に書く値:"
echo "  url: \"$url\""
echo "  checksum: \"$checksum\""
echo "添付する物:"
for file in "$staging"/*; do
  echo "  $(basename "$file")（$(stat -f %z "$file") bytes）"
done

# Package.swift が、この zip を指しているか（先に PR で url と checksum を直してから公開する）
package="$root/Packages/TheaterMedia/Package.swift"
if grep -qF "\"$url\"" "$package" && grep -qF "\"$checksum\"" "$package"; then
  echo "Package.swift はこの url と checksum を指しています"
else
  echo "注意: Package.swift の FFmpeg の binaryTarget が、この url と checksum ではありません（上の値に直してください）" >&2
  if [[ "$publish" == 1 ]]; then
    echo "エラー: Package.swift と食い違うものは公開しません" >&2
    exit 1
  fi
fi

if [[ "$publish" != 1 ]]; then
  echo
  echo "確かめるだけで終わりました。公開するときは --publish を付けて実行してください"
  exit 0
fi

if gh release view "$tag" -R "$repository" >/dev/null 2>&1; then
  echo "エラー: Release ${tag} はもうあります（同じ作り方なら、Package.swift はその url と checksum のままでよい）" >&2
  exit 1
fi
step "Release ${tag} を作る（公開）"
gh release create "$tag" -R "$repository" \
  --target "$commit" \
  --title "FFmpeg $ffmpeg_version（dav1d $dav1d_version）for visionOS" \
  --notes-file "$staging/notes.md" \
  --latest=false \
  "$staging/FFmpeg.xcframework.zip" \
  "$staging/ffmpeg-$ffmpeg_version.tar.xz" \
  "$staging/dav1d-$dav1d_version.tar.xz" \
  "$staging/ffmpeg-$ffmpeg_version-theater-player.diff" \
  "$staging/build-ffmpeg.sh"
echo "作りました: https://github.com/$repository/releases/tag/$tag"
