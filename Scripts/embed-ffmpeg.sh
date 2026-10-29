#!/bin/bash
# Xcode "Embed FFmpeg" run-script phase for the VoiceEraser app target.
#
# Copies Vendor/FFmpeg/bin/{ffmpeg,ffprobe} (built by Scripts/build-ffmpeg.sh)
# into VoiceEraser.app/Contents/Helpers and signs them with the app's identity
# and the Hardened Runtime, before Xcode signs the app bundle itself.
#
# If the binaries are missing the build fails with instructions, unless
# VOICEERASER_ALLOW_MISSING_FFMPEG=YES (the app then reports FFmpeg as missing
# at runtime).

set -euo pipefail

src="${PROJECT_DIR}/Vendor/FFmpeg/bin"
dest="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"

if [[ ! -x "$src/ffmpeg" || ! -x "$src/ffprobe" ]]; then
  if [[ "${VOICEERASER_ALLOW_MISSING_FFMPEG:-NO}" == "YES" ]]; then
    echo "warning: FFmpeg not found in $src; building without it."
    exit 0
  fi
  echo "error: FFmpeg not found in $src. Run Scripts/build-ffmpeg.sh first."
  exit 1
fi

mkdir -p "$dest"
for tool in ffmpeg ffprobe; do
  ditto "$src/$tool" "$dest/$tool"
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    codesign --force --sign "$identity" --options runtime --timestamp=none "$dest/$tool"
  fi
done
