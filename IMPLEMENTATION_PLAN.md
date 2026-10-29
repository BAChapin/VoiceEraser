# VoiceEraser — Implementation Plan

Tracks progress against `SPEC.md`. Updated as milestones land.

**Status:** Milestone 1 (first working app) implemented. Verified locally on Linux only where possible (see Verification log); everything that needs macOS is verified by CI. Not yet run by hand on a Mac.
**Last updated:** 2026-10-29

## Architecture summary

One Xcode project (`VoiceEraser.xcodeproj`, a SwiftUI macOS app) plus one local Swift package (`VoiceEraserKit/`). The package never imports SwiftUI; the app target is the only place that does.

| Area | Key types |
|---|---|
| Media (FFmpeg) | `FFmpegTools` (locates the bundled binaries), `MediaProbe`/`MediaInfo`/`MediaStream` (ffprobe JSON), `AudioEncodingPlan` (codec/bitrate/rate choice per track), `FFmpegCommands` (decode and mux argument lists), `ProcessRunner` |
| DSP | `ShortTimeFourierTransform` (matches `torch.stft`/`torch.istft`), `DemucsSpectrogram` (`HTDemucs._spec`/`_ispec`), `SegmentPlan` (`apply_model` segmenting and crossfade weights) |
| Engines | `SpeechRemovalEngine` protocol; `DemucsEngine` (Core ML); `VoiceIsolationEngine` (`AUSoundIsolation` + `SpectralMask`) |
| Pipeline | `SpeechRemovalPipeline` (probe → decode → engine → mux), `ScratchOutput` (atomic replace / save-as), `MappedPCMFile` (memory-mapped raw PCM), `ProgressThrottle` |
| App | `AppModel` (state, open/save panels, confirmation), `ContentView`, `FileDetailView`, `ProcessingStatusView` |

### Data flow

```
input file ──ffprobe──► MediaInfo
     │
     └─ for each audio track: ffmpeg decode ─► track-N-decoded.f32 (engine rate, all channels)
                                                  │ mmap
                                                  ▼
                                    SpeechRemovalEngine.removeSpeech
                                                  │ mmap
                                                  ▼
                                         track-N-processed.f32
     ┌────────────────────────────────────────────┘
     ▼
ffmpeg mux: copy video/subtitles/attachments/metadata from input,
            encode processed tracks per AudioEncodingPlan ──► ScratchOutput
                                                                   │
                                     replace original (atomic) ◄───┴───► save panel → move
```

## Technical decisions

1. **FFmpeg as bundled command-line tools.** `ffmpeg`/`ffprobe` live in `VoiceEraser.app/Contents/Helpers` and are driven with `Process`. Linking libav* from Swift would be far more code for the same result. The build is LGPL only (no `--enable-gpl`), static except for macOS system libraries, with AudioToolbox (`aac_at`) and LAME (MP3). `Scripts/build-ffmpeg.sh` refuses to finish if anything links outside `/usr/lib` or `/System`.
2. **App Sandbox off, Hardened Runtime on.** Personal/direct distribution (SPEC). Without the sandbox, in-place replacement and child processes reading user files need no security-scoped bookmarks or inherited entitlements.
3. **Demucs vocals model, STFT in Swift.** The model is the vocals specialist of `htdemucs_ft` (best vocals SDR of the public Demucs models). Core ML has no complex tensors, so `Scripts/convert-model.py` converts only the network between `_spec` and `_mask`, and the app reproduces the spectrogram in Swift. The converter asserts the wrapper equals `HTDemucs.forward` (max error 0.0 with random weights) and, on macOS, that Core ML matches PyTorch (≥ 25 dB SNR, fp16).
4. **Remove by subtraction, not by summing other stems.** Demucs output is `mix − vocals`, so anything the model doesn't call vocals (including its own errors on the other stems) passes through untouched.
5. **Segmenting identical to `apply_model(shifts=0, overlap=0.25)`.** 7.8 s segments, 25% overlap, triangular weights, context padding at the last segment. Verified against demucs with a NumPy port (max error 2.4e-8 over a 19.3 s signal).
6. **Apple Voice Isolation via spectral mask.** The audio unit's output is not guaranteed to be phase-aligned with its input, so the speech estimate becomes a soft mask `max(0, 1 − |V|/|M|)` (2048-point STFT, 75% overlap) rather than a subtraction. The unit's delay is measured by cross-correlation over the loudest 3 s of isolated voice, falling back to the reported latency.
7. **Memory-mapped raw PCM.** Decoded tracks (about 1.3 GB per stereo hour at 44.1 kHz) are mapped, not loaded, so long files don't need that much RAM.
8. **Output keeps the container and, where possible, the codec.** `AudioEncodingPlan` prefers the source codec (AudioToolbox AAC for AAC, including HE-AAC profiles), clamps channels/sample rates to what an encoder supports, and otherwise falls back to the container's usual codec. Mux retries without data streams, then without subtitles, if the container rejects one.
9. **Generated build inputs are not committed.** The FFmpeg binaries (~50 MB) and Core ML model (~70 MB fp16) are produced by scripts locally or in CI and cached by script hash. Without the model the app still builds and offers only Apple Voice Isolation.
10. **Apple Silicon only.** `ARCHS = arm64`; FFmpeg is built for arm64 only. Demucs at fp16 is impractically slow on Intel Macs anyway.

## Milestone 1 — First working app

### Completed (2026-10-29)

- SwiftUI app: drop zone / Choose File… (⌘O) / Finder Open With; file details; engine picker; Replace-original toggle with confirmation alert; progress with cancel; save panel with `<name> (No Speech).<ext>`; Show in Finder.
- `VoiceEraserKit`: everything in the architecture table.
- `Scripts/build-ffmpeg.sh` (FFmpeg 9.0.2 + LAME 3.100), `Scripts/embed-ffmpeg.sh` (Xcode build phase), `Scripts/convert-model.py`, `Scripts/make-dsp-fixtures.py`.
- CI: SwiftLint, FFmpeg build, model conversion with Core ML check, package tests (unit + integration), Release app build uploaded as an artifact. Tag-driven release workflow.

### Testing status

- Unit tests: STFT/iSTFT and Demucs spectrogram vs PyTorch fixtures, segment plan and overlap-add, ffprobe parsing, encoder list parsing, encoding plans, mux/decode arguments, progress parsing.
- Integration tests (CI): video with two audio tracks round-trips with all streams; MP3/FLAC/WAV/M4A/OGG round-trip; file without audio is rejected; atomic replace; Voice Isolation engine output bounded and lag estimate exact on a synthetic delay; Demucs Swift↔Core ML glue matches PyTorch on a reference segment (≥ 20 dB SNR); Demucs engine on a short mono clip.
- No UI tests yet.

### Verification log

- 2026-10-29 (Linux container, no Swift toolchain): model conversion with random weights succeeds with the pinned `Scripts/requirements.txt`; wrapper equals `HTDemucs.forward` exactly; a NumPy port of the Swift STFT/iSTFT/Demucs spectrogram matches PyTorch to ≤ 3e-7; segmenting port matches `apply_model` to 2.4e-8; the decode/mux argument lists (emulated) work with FFmpeg 6.1 on MP4 (2 audio tracks, languages, default flags, title), MP3, 24-bit FLAC, and MKV with 5.1 Opus and subtitles.
- Swift compilation, tests, and the app build: CI only (see the PR).

### Known limitations

- Not yet tried by hand on a Mac; quality of both engines on real dialogue is unmeasured.
- Demucs speed depends on Core ML's compute unit choice; expect roughly real time or slower on base M-series chips.
- Apple Voice Isolation quality is limited: it is a voice *enhancer*, and masking with its output leaves residual speech, especially in quiet passages.
- Tracks with more than two channels are processed by Demucs in channel pairs (for 5.1: FL/FR, FC/LFE, SL/SR), which is a stereo model applied off-label to non-stereo pairs.
- The app is ad-hoc signed in CI, not notarized: downloaded builds need the quarantine attribute cleared.
- Only the first file of a multi-file drop or Open With is used.

## Next development steps

1. Run on a Mac with real material (films, vlogs, podcasts with music beds); tune the mask and compare engines.
2. Before/after preview playback.
3. Developer ID signing and notarization in the release workflow.
4. UI tests for the open → confirm → process → save flow.
