#!/bin/bash
# App Store に出した版のソースを、GitHub の Release（タグ v<MARKETING_VERSION>）で配る（FFmpeg の LGPL 2.1 の手続き）。
# アプリの「ライセンス」の画面は、この Release（releases/tag/v<版>）へ案内する（README の「審査に出すときにすること」）。
#
# 使い方: scripts/publish-source-release.sh [--commit <コミット>] [--replace] [--publish]
#   既定は確かめるだけ: 出すコミット・版・添付する物を確かめ、添付する物を .build/source-release/v<版>/（本文は v<版>-notes.md）に用意して、
#   公開の内容を表示する。タグと Release は作らない
#   --commit   Release のタグを付けるコミット。省くと、develop の最新の成功した Upload（App Store Connect に上げた実行）のコミット
#   --replace  同じ版のタグと Release があれば、消して作り直す（同じ版でビルドを出し直したとき）
#   --publish  タグと Release を GitHub に作る（公開。誰でも見られる）
#
# 添付する物（すべて、そのコミットの scripts/build-ffmpeg.sh が使う版と同じ）:
#   ffmpeg-<版>.tar.xz・dav1d-<版>.tar.xz  公式の配布物。scripts/build-ffmpeg.sh が取得して SHA-256 を確かめた物（.build/ffmpeg/src）を使う
#   ffmpeg-<版>-theater-player.diff          FFmpeg に当てたパッチ（scripts/ffmpeg/patches/*.patch をつないだ物）
#   build-ffmpeg.sh                          FFmpeg の作り方（configure の指定）
# アプリ自身のソースは、GitHub がタグのソースの zip・tar.gz を自動で添付する。
#
# FFmpeg の配布物が無いときは、先に scripts/build-ffmpeg.sh xros を一度実行する（作業フォルダは FFMPEG_BUILD_DIR で変えられる）
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="${FFMPEG_BUILD_DIR:-$root/.build/ffmpeg}"

commit=""
replace=0
publish=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)
      commit="${2:?--commit にコミットを指定してください}"
      shift 2
      ;;
    --replace)
      replace=1
      shift
      ;;
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

# リポジトリ（owner/name）は origin の URL から決める。gh が upstream などを既定にしていても取り違えない
origin_url="$(git -C "$root" remote get-url origin)"
repository="$(printf '%s\n' "$origin_url" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "エラー: origin（${origin_url}）から GitHub のリポジトリを決められません" >&2
  exit 1
fi

# 出すコミット。省いたら、develop の最新の成功した Upload の実行のコミット（App Store Connect に最後に上げたビルド）
upload_runs() {
  gh run list -R "$repository" --workflow upload.yml --status success --limit 100 \
    --json headSha,headBranch,createdAt,url "$@"
}
git -C "$root" fetch --quiet origin
if [[ -z "$commit" ]]; then
  step "develop の最新の成功した Upload を調べる"
  run="$(upload_runs --branch develop --jq 'if length > 0 then (first | "\(.headSha) \(.createdAt) \(.url)") else empty end')"
  if [[ -z "$run" ]]; then
    echo "エラー: develop の成功した Upload が見つかりません。--commit で指定してください" >&2
    exit 1
  fi
  read -r commit run_time run_url <<< "$run"
  echo "Upload: ${run_time}（UTC） ${run_url}"
  echo "  App Store Connect で審査に出すビルドが、この時刻に上がったビルドか確かめてください"
else
  commit="$(git -C "$root" rev-parse --verify "$commit^{commit}")"
  run="$(upload_runs --jq "map(select(.headSha == \"$commit\")) | if length > 0 then (first | \"\(.createdAt) \(.url)\") else empty end")"
  if [[ -n "$run" ]]; then
    echo "Upload: $run"
  else
    echo "注意: このコミットの成功した Upload が見つかりません（App Store Connect に上げたビルドのコミットか確かめてください）" >&2
  fi
fi
if ! git -C "$root" cat-file -e "$commit^{commit}" 2>/dev/null; then
  echo "エラー: コミット ${commit} が手元にありません（git fetch してください）" >&2
  exit 1
fi
if ! git -C "$root" branch -r --contains "$commit" | grep -q .; then
  echo "エラー: コミット ${commit} は GitHub に push されていません" >&2
  exit 1
fi
echo "コミット: $(git -C "$root" log -1 --format='%h %s（%ci）' "$commit")"

# そのコミットのファイルを読む
show() {
  git -C "$root" show "$commit:$1"
}
setting() {
  # $1 のファイルから「名前 = 値」「名前=値」の値を取り出す
  show "$1" | sed -n -E "s/^$2 *= *([^ ]*).*/\1/p" | head -n 1
}

version="$(setting Configs/Project.xcconfig MARKETING_VERSION)"
ffmpeg_version="$(setting scripts/build-ffmpeg.sh FFMPEG_VERSION)"
ffmpeg_sha="$(setting scripts/build-ffmpeg.sh FFMPEG_SHA256)"
dav1d_version="$(setting scripts/build-ffmpeg.sh DAV1D_VERSION)"
dav1d_sha="$(setting scripts/build-ffmpeg.sh DAV1D_SHA256)"
for pair in "version=$version" "ffmpeg_version=$ffmpeg_version" "ffmpeg_sha=$ffmpeg_sha" "dav1d_version=$dav1d_version" "dav1d_sha=$dav1d_sha"; do
  if [[ -z "${pair#*=}" ]]; then
    echo "エラー: ${pair%%=*} を読めません（Configs/Project.xcconfig・scripts/build-ffmpeg.sh）" >&2
    exit 1
  fi
done
tag="v$version"
echo "版: ${tag}（FFmpeg ${ffmpeg_version}・dav1d ${dav1d_version}）"

# アプリのライセンスの画面の版と揃っているか（scripts/build-ffmpeg.sh と同じ確かめ方）
licenses="$(show TheaterPlayer/About/OpenSourceLicenses.swift)"
for pair in "ffmpegVersion=$ffmpeg_version" "dav1dVersion=$dav1d_version"; do
  if ! grep -q "static let ${pair%%=*} = \"${pair#*=}\"" <<< "$licenses"; then
    echo "エラー: そのコミットの OpenSourceLicenses.swift の ${pair%%=*} が ${pair#*=} ではありません" >&2
    exit 1
  fi
done

# 添付する物を用意する
staging="$root/.build/source-release/$tag"
step "添付する物を用意する（${staging}）"
rm -rf "$staging"
mkdir -p "$staging"
copy_archive() {
  local name="$1" sha="$2" file="$work/src/$1"
  if [[ ! -f "$file" ]]; then
    echo "エラー: ${file} がありません。先に scripts/build-ffmpeg.sh xros を実行してください（公式の配布物を取得して SHA-256 を確かめます）" >&2
    exit 1
  fi
  if ! echo "$sha  $file" | shasum -a 256 -c --status; then
    echo "エラー: ${name} の SHA-256 が scripts/build-ffmpeg.sh の値と一致しません" >&2
    exit 1
  fi
  cp "$file" "$staging/$name"
}
copy_archive "ffmpeg-$ffmpeg_version.tar.xz" "$ffmpeg_sha"
copy_archive "dav1d-$dav1d_version.tar.xz" "$dav1d_sha"
diff_file="ffmpeg-$ffmpeg_version-theater-player.diff"
while IFS= read -r patch_file; do
  show "$patch_file"
  echo
done < <(git -C "$root" ls-tree --name-only "$commit" scripts/ffmpeg/patches/ | grep '\.patch$') > "$staging/$diff_file"
show scripts/build-ffmpeg.sh > "$staging/build-ffmpeg.sh"
(cd "$staging" && shasum -a 256 ./*)

release_url="https://github.com/$repository/releases/tag/$tag"
notes="$root/.build/source-release/$tag-notes.md"
cat > "$notes" <<EOF
The source code of Theater Player $version as submitted to the App Store (commit $commit).

This software uses code of [FFmpeg](https://ffmpeg.org) licensed under the [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) and its source can be downloaded [here]($release_url).

- \`ffmpeg-$ffmpeg_version.tar.xz\`: the FFmpeg $ffmpeg_version source distribution (LGPL 2.1 or later), unmodified from ffmpeg.org
- \`$diff_file\`: the changes applied to FFmpeg to build it for visionOS (the same as \`scripts/ffmpeg/patches/\` in this tag)
- \`build-ffmpeg.sh\`: how FFmpeg was built (the configure options). FFmpeg is built without GPL or nonfree components and statically linked into the app
- \`dav1d-$dav1d_version.tar.xz\`: the dav1d $dav1d_version source distribution (BSD 2-Clause), unmodified from videolan.org
- Source code (zip / tar.gz): the source code of this app (MIT License). You can replace FFmpeg and rebuild the app with it (see README)

---

App Store に出した版（コミット $commit）のソースです。FFmpeg $ffmpeg_version（LGPL 2.1 以降）と dav1d $dav1d_version（BSD 2-Clause）の公式の配布物、FFmpeg に当てたパッチ（\`$diff_file\`）、FFmpeg の作り方（\`build-ffmpeg.sh\`）を添付しています。アプリのソース（MIT License）はタグの Source code です。
EOF

step "公開する内容"
echo "  リポジトリ: $repository"
echo "  タグ: ${tag}（$commit）"
echo "  Release: $release_url"
assets=("$staging"/*)
echo "  添付: ${assets[*]##*/}"

existing=0
if gh release view "$tag" -R "$repository" >/dev/null 2>&1 || git -C "$root" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  existing=1
  echo "  $tag のタグか Release がすでにあります（作り直すなら --replace）"
fi

if [[ "$publish" != 1 ]]; then
  echo
  echo "確かめるだけで終えました。公開するときは --publish を付けて実行してください（Release の本文: ${notes}）"
  exit 0
fi

if [[ "$existing" == 1 ]]; then
  if [[ "$replace" != 1 ]]; then
    echo "エラー: $tag はすでにあります。同じ版でビルドを出し直したなら --replace を付けてください" >&2
    exit 1
  fi
  step "$tag の Release とタグを消す"
  gh release delete "$tag" -R "$repository" --cleanup-tag --yes 2>/dev/null ||
    gh api -X DELETE "repos/$repository/git/refs/tags/$tag" >/dev/null 2>&1 || true
fi

step "$tag の Release を作る"
gh release create "$tag" "${assets[@]}" -R "$repository" --target "$commit" \
  --title "Theater Player $version" --notes-file "$notes" --latest
echo "作りました: $release_url"
