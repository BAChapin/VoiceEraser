#!/bin/bash
# Builds the ffmpeg and ffprobe command-line tools that VoiceEraser bundles in
# VoiceEraser.app/Contents/Helpers.
#
# - LGPL only: no --enable-gpl / --enable-nonfree components.
# - Statically linked against FFmpeg's own libraries and LAME (MP3 encoding);
#   dynamically linked only against macOS system frameworks and libraries,
#   so the binaries run on any Mac with macOS 26 or later.
# - Autodetection is disabled so nothing installed on the build machine (for
#   example Homebrew libraries) leaks into the binaries.
# - Video is only ever stream-copied by VoiceEraser, but FFmpeg's native
#   video encoders are left in; they cost a few MB and keep the build simple.
#
# Usage: Scripts/build-ffmpeg.sh [output-dir]   (default: Vendor/FFmpeg)
# Output: <output-dir>/bin/ffmpeg, <output-dir>/bin/ffprobe, <output-dir>/VERSION

set -euo pipefail

# Checksums cross-checked against the Homebrew ffmpeg and lame formulae.
FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
LAME_VERSION="3.100"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
MACOS_DEPLOYMENT_TARGET="26.0"
ARCH="arm64"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${1:-$repo_root/Vendor/FFmpeg}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
stamp="ffmpeg-${FFMPEG_VERSION}+lame-${LAME_VERSION}-${ARCH}-macos${MACOS_DEPLOYMENT_TARGET}"

if [[ -x "$out_dir/bin/ffmpeg" && -x "$out_dir/bin/ffprobe" && "$(cat "$out_dir/VERSION" 2>/dev/null)" == "$stamp" ]]; then
  echo "FFmpeg already built: $out_dir ($stamp)"
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: FFmpeg for VoiceEraser must be built on macOS." >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/voiceeraser-ffmpeg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
jobs="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
common_cflags="-arch $ARCH -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET -O2"

fetch() {
  local url="$1" sha="$2" file="$3"
  curl -sSL --fail --retry 3 -o "$file" "$url"
  echo "$sha  $file" | shasum -a 256 --check
}

echo "==> LAME $LAME_VERSION"
fetch "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" \
  "$LAME_SHA256" "$work/lame.tar.gz"
tar -xzf "$work/lame.tar.gz" -C "$work"
(
  cd "$work/lame-$LAME_VERSION"
  # lame_init_old is listed in the export list but not defined; the macOS
  # linker rejects that (same fix as Homebrew's lame formula).
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym
  ./configure --prefix="$prefix" --build=aarch64-apple-darwin --host=aarch64-apple-darwin \
    --disable-shared --enable-static --disable-frontend --disable-decoder \
    --disable-dependency-tracking \
    CFLAGS="$common_cflags -Wno-implicit-function-declaration" LDFLAGS="-arch $ARCH"
  make -j"$jobs" install
)

echo "==> FFmpeg $FFMPEG_VERSION"
fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" "$FFMPEG_SHA256" "$work/ffmpeg.tar.xz"
tar -xJf "$work/ffmpeg.tar.xz" -C "$work"
(
  cd "$work/ffmpeg-$FFMPEG_VERSION"
  ./configure \
    --prefix="$prefix" \
    --arch="$ARCH" \
    --cc=clang \
    --enable-static --disable-shared \
    --disable-autodetect \
    --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv \
    --enable-libmp3lame \
    --disable-ffplay --disable-doc --disable-network --disable-debug \
    --disable-indevs --disable-outdevs \
    --extra-cflags="$common_cflags -I$prefix/include" \
    --extra-ldflags="-arch $ARCH -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET -L$prefix/lib" \
    --extra-libs="-liconv"
  make -j"$jobs"
  make install
)

mkdir -p "$out_dir/bin"
for tool in ffmpeg ffprobe; do
  install -m 755 "$prefix/bin/$tool" "$out_dir/bin/$tool"
  strip -x "$out_dir/bin/$tool"
done

# Fail if anything other than system libraries got linked dynamically.
for tool in ffmpeg ffprobe; do
  if otool -L "$out_dir/bin/$tool" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
    echo "error: $tool links a non-system library (above)." >&2
    exit 1
  fi
done

"$out_dir/bin/ffmpeg" -hide_banner -version | head -1
echo "$stamp" > "$out_dir/VERSION"
echo "FFmpeg built: $out_dir"
