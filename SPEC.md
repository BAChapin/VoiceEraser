# VoiceEraser — Product Spec

VoiceEraser is a macOS app that removes human speech from the soundtrack of a video or audio file and keeps everything else (music, ambience, sound effects).

## Platform

- macOS 26 or later, Apple Silicon (arm64).
- Distributed directly (not through the Mac App Store). App Sandbox off, Hardened Runtime on.
- Fully offline. No network access, accounts, or telemetry.

## Inputs

- Any audio or video file FFmpeg can read (for example MP4, MOV, M4V, MKV, WebM, AVI, MP3, M4A, WAV, AIFF, FLAC, OGG, Opus, WMA).
- The user opens a file with **Choose File…** (⌘O), by dropping it on the window, or by dropping it on the Dock icon / using **Open With**.
- A file without an audio track is rejected with an explanation.

## Main window

1. **Empty state:** drop zone and **Choose File…** button.
2. **File loaded:** file name, kind (video or audio), duration, and audio track details (codec, channels, sample rate).
3. **Engine picker:**
   - **High Quality (Demucs):** on-device neural source separation (Hybrid Transformer Demucs, vocals model). Slower, best quality.
   - **Fast (Apple Voice Isolation):** Apple's built-in voice isolation audio unit, used to estimate speech, which is then masked out of the mix. Faster, lower quality.
   - If the Demucs model is not in the app bundle, that option is disabled with an explanation.
4. **Replace original file** toggle, off by default.
   - Turning it on shows a confirmation alert ("Replace the original file?"; **Replace Original** / **Cancel**). Cancel leaves the toggle off.
5. **Remove Speech** button starts processing.
6. **Processing:** stage label (Decoding, Removing speech, Encoding), progress bar, and **Cancel**. Cancelling leaves the original file untouched and deletes temporary files.

## Output

- **Toggle on:** the original file is replaced in place (atomically, so a failure never leaves a half-written file). Video and all non-audio streams are copied bit-for-bit; only the audio is re-encoded.
- **Toggle off:** when processing finishes, a save panel asks where to save. Default name `<name> (No Speech).<ext>`. If the user cancels the panel, the result is kept and can be saved later with **Save…** or discarded.
- After either path the window shows where the file went, with **Show in Finder**.

### Format rules

- The output keeps the input's container (file extension).
- Every audio track is processed. Each is re-encoded with the same codec, sample rate, channel layout, and (for lossy codecs) bitrate when FFmpeg has an encoder for it; otherwise with the container's fallback codec (for example AAC for MP4/MOV/MKV, Opus for WebM, PCM for WAV).
- Video, subtitle, attachment, cover art, chapters, and metadata are copied. If the container refuses a stream when muxing, data streams and then subtitles are dropped, in that order, rather than failing.

## Speech removal

- Speech is estimated by the selected engine and removed from the original mix: `output = mix − speech` (Demucs) or a spectral mask `1 − |speech| / |mix|` applied to the mix (Apple Voice Isolation). Anything the engine does not classify as speech is left as it was.
- Demucs runs on 44.1 kHz stereo segments of 7.8 s with 25% overlap and linear crossfades, as in the reference implementation. Mono tracks are duplicated to stereo; tracks with more than two channels are processed in channel pairs.
- Apple Voice Isolation processes each channel separately.

## Non-goals (for now)

- Batch processing of multiple files.
- Preview playback or before/after comparison.
- Partial removal (strength slider) or keeping speech and removing everything else.
- Signing, notarization, and distribution builds.
