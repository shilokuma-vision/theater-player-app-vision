#!/bin/bash
# FFmpeg（AV1 のソフトウェアデコードに使う dav1d を含む）を visionOS 向けにビルドし、
# Packages/TheaterMedia/Vendor/FFmpeg.xcframework（静的ライブラリ 1 つ + ヘッダー）を作る。
#
# 使い方: scripts/build-ffmpeg.sh [xros] [xrsimulator]
#   引数を省くと実機（xros）と Simulator（xrsimulator）の両方を作る。CI では使う方だけを渡す
#   作業フォルダは .build/ffmpeg/（FFMPEG_BUILD_DIR で変えられる）。ソースは公式の配布物を SHA-256 で確かめてから使う
#   作った内容は Vendor/FFmpeg.stamp に書く。同じ内容のものがあれば何もしない（作り直すときは FFMPEG_FORCE=1）
#
# ライセンス: FFmpeg は LGPL 2.1 以降、dav1d は BSD 2-Clause。GPL・nonfree のコンポーネントは有効にしない
#   （configure に --enable-gpl / --enable-nonfree を渡さない。--disable-autodetect で意図しない外部ライブラリも入れない。
#   --disable-autodetect はスレッド（pthreads）も外すので、--enable-pthreads で明示的に入れる）
set -euo pipefail

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
DAV1D_VERSION=1.5.4
DAV1D_SHA256=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
# dav1d のビルドに使う meson / ninja（Python の仮想環境に入れる。システムには入れない）
# meson 1.12 以降は Python 3.10 以上が要る。macOS の標準の python3（3.9）でも入る 1.11 系にする
MESON_VERSION=1.11.2
NINJA_VERSION=1.13.2

root="$(cd "$(dirname "$0")/.." && pwd)"
work="${FFMPEG_BUILD_DIR:-$root/.build/ffmpeg}"
vendor="$root/Packages/TheaterMedia/Vendor"
output="$vendor/FFmpeg.xcframework"
stamp="$vendor/FFmpeg.stamp"
jobs="$(sysctl -n hw.ncpu)"

# 最低サポート OS はアプリと揃える（Configs/Project.xcconfig の XROS_DEPLOYMENT_TARGET）
deployment_target="$(sed -n 's/^XROS_DEPLOYMENT_TARGET *= *\([0-9.]*\).*/\1/p' "$root/Configs/Project.xcconfig")"
if [[ -z "$deployment_target" ]]; then
  echo "エラー: Configs/Project.xcconfig に XROS_DEPLOYMENT_TARGET が見つかりません" >&2
  exit 1
fi

platforms=("$@")
if [[ ${#platforms[@]} -eq 0 ]]; then
  platforms=(xros xrsimulator)
fi
for platform in "${platforms[@]}"; do
  case "$platform" in
    xros | xrsimulator) ;;
    *)
      echo "エラー: プラットフォームは xros か xrsimulator です（$platform）" >&2
      exit 1
      ;;
  esac
done

# 同じ設定で作ったものがあれば作り直さない（スクリプトの中身・バージョン・OS・プラットフォームが同じとき）
script_hash="$(cat "$0" "$root/scripts/ffmpeg/pkg-config" | shasum -a 256 | cut -d' ' -f1)"
stamp_content="ffmpeg=$FFMPEG_VERSION dav1d=$DAV1D_VERSION target=$deployment_target platforms=${platforms[*]} script=$script_hash"
if [[ "${FFMPEG_FORCE:-0}" != 1 && -d "$output" && -f "$stamp" && "$(cat "$stamp")" == "$stamp_content" ]]; then
  echo "FFmpeg.xcframework は最新です（$stamp_content）"
  exit 0
fi

mkdir -p "$work/src"

# ソースを取得して SHA-256 を確かめ、展開する
fetch() {
  local url="$1" sha="$2" file="$work/src/$(basename "$1")"
  if [[ ! -f "$file" ]] || ! echo "$sha  $file" | shasum -a 256 -c --status; then
    echo "取得: $url"
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if ! echo "$sha  $file" | shasum -a 256 -c --status; then
    echo "エラー: $(basename "$file") の SHA-256 が一致しません" >&2
    exit 1
  fi
}
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
fetch "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" "$DAV1D_SHA256"

# meson / ninja を仮想環境に入れる
venv="$work/venv"
if [[ ! -x "$venv/bin/meson" || ! -x "$venv/bin/ninja" ]]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check "meson==$MESON_VERSION" "ninja==$NINJA_VERSION"
fi
export PATH="$venv/bin:$PATH"

# 展開したソース（プラットフォームごとに作り直す。configure がソースの中に何も書かないよう、ビルドは別のフォルダで行う）
extract() {
  local name="$1"
  rm -rf "$work/src/$name"
  tar xf "$work/src/$name.tar.xz" -C "$work/src"
}
extract "ffmpeg-$FFMPEG_VERSION"
extract "dav1d-$DAV1D_VERSION"

target_triple() {
  if [[ "$1" == xrsimulator ]]; then
    echo "arm64-apple-xros$deployment_target-simulator"
  else
    echo "arm64-apple-xros$deployment_target"
  fi
}

build_dav1d() {
  local platform="$1" prefix="$2"
  local sdk cc triple build="$work/$platform/dav1d"
  sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
  cc="$(xcrun --sdk "$platform" -f clang)"
  triple="$(target_triple "$platform")"
  rm -rf "$build"
  mkdir -p "$build"
  cat > "$build/cross.ini" <<EOF
[binaries]
c = '$cc'
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'

[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$sdk']
c_link_args = ['-target', '$triple', '-isysroot', '$sdk']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
  meson setup "$build/out" "$work/src/dav1d-$DAV1D_VERSION" \
    --cross-file "$build/cross.ini" \
    --prefix "$prefix" --libdir lib \
    --buildtype release \
    -Ddefault_library=static \
    -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false \
    -Dlogging=false
  ninja -C "$build/out" install
}

build_ffmpeg() {
  local platform="$1" prefix="$2"
  local sdk cc triple build="$work/$platform/ffmpeg"
  sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
  cc="$(xcrun --sdk "$platform" -f clang)"
  triple="$(target_triple "$platform")"
  rm -rf "$build"
  mkdir -p "$build"
  (
    cd "$build"
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" "$work/src/ffmpeg-$FFMPEG_VERSION/configure" \
      --prefix="$prefix" \
      --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc="$cc" --sysroot="$sdk" \
      --extra-cflags="-target $triple" --extra-ldflags="-target $triple" \
      --pkg-config="$root/scripts/ffmpeg/pkg-config" --pkg-config-flags=--static \
      --enable-static --disable-shared --enable-pic \
      --disable-autodetect --disable-debug --disable-doc --disable-programs \
      --disable-avdevice --disable-network \
      --disable-encoders --disable-muxers --disable-indevs --disable-outdevs \
      --disable-protocols --enable-protocol=file \
      --disable-filters \
      --enable-filter=abuffer,abuffersink,buffer,buffersink,aformat,format,aresample,atempo,bwdif,yadif,null,anull,scale \
      --enable-pthreads \
      --enable-videotoolbox --enable-audiotoolbox \
      --enable-zlib --enable-bzlib --enable-iconv \
      --enable-libdav1d
    make -j"$jobs"
    make install
  )
}

# 1 つのプラットフォームを作る。静的ライブラリは 1 つ（libffmpeg.a）にまとめる
build_platform() {
  local platform="$1"
  local prefix="$work/$platform/prefix"
  echo "=== $platform（$(target_triple "$platform")）"
  rm -rf "$prefix"
  build_dav1d "$platform" "$prefix"
  build_ffmpeg "$platform" "$prefix"
  rm -f "$work/$platform/libffmpeg.a"
  xcrun libtool -static -o "$work/$platform/libffmpeg.a" \
    "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" "$prefix/lib/libavfilter.a" \
    "$prefix/lib/libswscale.a" "$prefix/lib/libswresample.a" "$prefix/lib/libavutil.a" \
    "$prefix/lib/libdav1d.a"
}

args=()
for platform in "${platforms[@]}"; do
  build_platform "$platform"
  args+=(-library "$work/$platform/libffmpeg.a" -headers "$work/$platform/prefix/include")
done

rm -rf "$output"
mkdir -p "$vendor"
xcodebuild -create-xcframework "${args[@]}" -output "$output"
echo "$stamp_content" > "$stamp"
echo "作成: $output（$stamp_content）"
