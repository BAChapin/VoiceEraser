# VoiceEraser

A macOS app that removes human speech from a video or audio file and keeps the music, ambience, and sound effects.

- Add one file or a whole batch (files or folders) of anything FFmpeg can read (MP4, MOV, MKV, WebM, MP3, M4A, WAV, FLAC, …).
- Choose **High Quality (Demucs)** (on-device neural source separation) or **Fast (Apple Voice Isolation)**.
- Either replace the audio in the original files (after one confirmation) or save new copies to a folder of your choice. Video and other streams are copied untouched.
- Everything runs offline.

Requires macOS 26 on Apple Silicon. See `SPEC.md` for the product spec and `IMPLEMENTATION_PLAN.md` for design decisions and status.

## Building

The FFmpeg binaries and the Core ML model are generated, not committed:

```bash
Scripts/build-ffmpeg.sh
```

```bash
python3 -m venv .venv && .venv/bin/pip install -r Scripts/requirements.txt && .venv/bin/pip install --no-deps demucs==4.0.1
```

```bash
.venv/bin/python Scripts/convert-model.py
```

Then open `VoiceEraser.xcodeproj` and run the **VoiceEraser** scheme. CI also uploads a ready-built, ad-hoc signed app as the `VoiceEraser-app` artifact on every run. To open a downloaded build, clear the quarantine flag first:

```bash
xattr -dr com.apple.quarantine VoiceEraser.app
```

## Credits

- [Demucs](https://github.com/facebookresearch/demucs) (Hybrid Transformer Demucs, `htdemucs_ft` vocals model) by Meta AI Research, MIT License.
- [FFmpeg](https://ffmpeg.org) (LGPL 2.1+) and [LAME](https://lame.sourceforge.io) (LGPL 2.0+), built from source by `Scripts/build-ffmpeg.sh`.
