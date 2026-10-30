#!/bin/bash
# AC-3・E-AC-3 のストリームの DRC（音量の幅の圧縮）を確かめるための音のファイルを作る。
#
# 使い方: scripts/make-drc-test-files.sh [実機で聞くファイルを置くフォルダ]
#   - テスト用（Packages/TheaterMedia/Tests/TheaterMediaTests/Fixtures/dynrng-12db.ac3・.eac3）を作り直す
#   - 実機で聞くファイル（drc-check-5.1.ac3・.eac3）を、引数のフォルダ（省くと .build/drc-test/out）に作る
#
# Mac の道具だけでは作れない：afconvert は AC-3・E-AC-3 を読めるが書けない（エンコーダーが無い）。
# FFmpeg のエンコーダーは書けるが、DRC の値を書かない（どのブロックも dynrnge = 0）ので、drc_scale を変えても音が変わらない。
# そこで FFmpeg のソースに scripts/drc-test/ac3enc-test-dynrng.patch を当てて、この Mac で動く ffmpeg を作る
# （作業フォルダは .build/drc-test。アプリの FFmpeg（scripts/build-ffmpeg.sh）とは別で、Vendor には触れない）。
# ソースは scripts/build-ffmpeg.sh と同じ版・SHA-256 のものを使う（.build/ffmpeg/src にあればそれを使う）。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/.build/drc-test"
output="${1:-$work/out}"
fixtures="$root/Packages/TheaterMedia/Tests/TheaterMediaTests/Fixtures"
patch_file="$root/scripts/drc-test/ac3enc-test-dynrng.patch"
version="$(sed -n 's/^FFMPEG_VERSION=//p' "$root/scripts/build-ffmpeg.sh")"
sha256="$(sed -n 's/^FFMPEG_SHA256=//p' "$root/scripts/build-ffmpeg.sh")"
tarball="$root/.build/ffmpeg/src/ffmpeg-$version.tar.xz"
ffmpeg="$work/ffmpeg-$version/ffmpeg"
stamp="$work/ffmpeg.stamp"

step() {
  echo "==> $*"
}

# この Mac で動く ffmpeg（パッチを当てたもの。パッチが同じなら作り直さない）
stamp_content="ffmpeg=$version patch=$(shasum -a 256 "$patch_file" | cut -d' ' -f1)"
if [[ ! -x "$ffmpeg" || ! -f "$stamp" || "$(cat "$stamp")" != "$stamp_content" ]]; then
  mkdir -p "$work"
  if [[ ! -f "$tarball" ]] || ! echo "$sha256  $tarball" | shasum -a 256 -c --status; then
    tarball="$work/ffmpeg-$version.tar.xz"
    if [[ ! -f "$tarball" ]] || ! echo "$sha256  $tarball" | shasum -a 256 -c --status; then
      step "FFmpeg $version のソースを取得する"
      curl -fL --retry 3 -o "$tarball.part" "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
      mv "$tarball.part" "$tarball"
    fi
    if ! echo "$sha256  $tarball" | shasum -a 256 -c --status; then
      echo "エラー: ffmpeg-$version.tar.xz の SHA-256 が一致しません" >&2
      exit 1
    fi
  fi
  step "パッチを当てた ffmpeg を作る（$work）"
  rm -rf "$work/ffmpeg-$version"
  tar -xJf "$tarball" -C "$work"
  (cd "$work/ffmpeg-$version" && patch -p1 --quiet < "$patch_file")
  (
    cd "$work/ffmpeg-$version"
    # 音のファイルを作るのに要るものだけを入れる（configure の確かめが少なく、早く終わる）
    ./configure \
      --disable-autodetect --disable-doc --disable-debug --disable-network \
      --disable-avdevice --disable-swscale --disable-everything \
      --enable-ffmpeg --disable-ffplay --disable-ffprobe --enable-pthreads \
      --enable-protocol=file,pipe \
      --enable-encoder=ac3,eac3 --enable-decoder=ac3,eac3 \
      --enable-muxer=ac3,eac3 --enable-demuxer=ac3,eac3 \
      --enable-filter=aevalsrc,afade,aformat,aresample,anull,abuffer,abuffersink \
      > "$work/configure.log"
    make -j"$(sysctl -n hw.ncpu)" ffmpeg > "$work/make.log"
  )
  echo "$stamp_content" > "$stamp"
fi

# 5.1 の正弦波（フロント左・右・センター・サラウンド左・右に amplitude、LFE に 50 Hz）
tones() {
  local amplitude="$1" frequency="$2"
  local tone="$amplitude*sin(2*PI*$frequency*t)"
  echo "$tone|$tone|$tone|$amplitude*sin(2*PI*50*t)|$tone|$tone"
}

encode() {
  local codec="$1" file="$2" duration="$3" expressions="$4" filters="${5:-anull}"
  "$ffmpeg" -hide_banner -loglevel error -y \
    -filter_complex "aevalsrc=exprs='$expressions':channel_layout=5.1:sample_rate=48000:duration=$duration,$filters" \
    -c:a "$codec" -b:a 448k "$file"
}

# テスト用：0.64 秒（20 フレーム）。振幅 0.1（-20 dBFS）の 1 kHz、どのフレームも DRC の値 0xC0（-12.04 dB）
step "テスト用のファイルを作る（${fixtures#"$root/"}）"
mkdir -p "$fixtures"
for codec in ac3 eac3; do
  TP_DYNRNG_CODE=0xC0 encode "$codec" "$fixtures/dynrng-12db.$codec" 0.64 "$(tones 0.1 1000)"
done

# 実機で聞く：16 秒。A の和音（左前 440 Hz・右前 554 Hz・センター 659 Hz・サラウンド左 330 Hz・右 277 Hz・LFE 55 Hz）を
# 同じ大きさ（-24 dBFS）で鳴らし、約 2 秒（63 フレーム）ごとに DRC の値を 0 dB と 0xA0（-18.06 dB）で入れ替える。
# ストリームの DRC をかけなければ大きさは変わらず、かければ 2 秒ごとに小さくなる
step "実機で聞くファイルを作る（$output）"
mkdir -p "$output"
chord="0.063*sin(2*PI*440*t)|0.063*sin(2*PI*554.37*t)|0.063*sin(2*PI*659.26*t)|0.063*sin(2*PI*55*t)|0.063*sin(2*PI*329.63*t)|0.063*sin(2*PI*277.18*t)"
fades="afade=t=in:duration=0.05,afade=t=out:start_time=15.9:duration=0.1"
for codec in ac3 eac3; do
  TP_DYNRNG_CODE=0xA0 TP_DYNRNG_PERIOD=63 encode "$codec" "$output/drc-check-5.1.$codec" 16 "$chord" "$fades"
done
ls -l "$fixtures"/dynrng-12db.* "$output"/drc-check-5.1.*
