# VoiceEraser — Product Spec

VoiceEraser is a macOS app that removes human speech from the soundtrack of a video or audio file and keeps everything else (music, ambience, sound effects).

## Platform

- macOS 26 or later, Apple Silicon (arm64).
- Distributed directly (not through the Mac App Store). App Sandbox off, Hardened Runtime on.
- Fully offline. No network access, accounts, or telemetry.

## Inputs

- Any audio or video file FFmpeg can read (for example MP4, MOV, M4V, MKV, WebM, AVI, MP3, M4A, WAV, AIFF, FLAC, OGG, Opus, WMA).
- The user adds files with **Add Files…** / **Choose Files…** (⌘O), by dropping them on the window, or by dropping them on the Dock icon / using **Open With**. Any number of files can be added at once.
- Adding a folder adds the audio and video files inside it (recursively; hidden files skipped). Files already in the list are not added twice.
- A file that can't be read, or has no audio track, stays in the list marked as failed with an explanation.

## Main window

1. **Empty state:** drop zone and **Choose Files…** button.
2. **Batch list:** one row per file with its name, kind (video or audio), duration, number of audio tracks, and first track's details (codec, channels, sample rate, bitrate). Rows can be removed (✕ or context menu); **Remove ▸ Remove Finished / Remove All**.
3. **Engine picker** (applies to the whole batch):
   - **High Quality (Demucs):** on-device neural source separation (Hybrid Transformer Demucs, vocals model). Slower, best quality.
   - **Fast (Apple Voice Isolation):** Apple's built-in voice isolation audio unit, used to estimate speech, which is then masked out of the mix. Faster, lower quality.
   - If the Demucs model is not in the app bundle, that option is disabled with an explanation.
4. **Replace audio in the original files** toggle, off by default.
   - Turning it on shows one confirmation alert for the batch ("Replace the original files?"; **Replace Originals** / **Cancel**). It covers every file in the list, including files added later. Cancel leaves the toggle off. **Remove All** turns it back off.
   - When off, the window shows the **output folder** with **Choose…**. If none is chosen when processing starts, a folder panel asks first.
5. **Remove Speech from N Files** processes every ready file, one at a time, in list order.
6. **Processing:** each row shows its own stage (Decoding, Removing speech, Encoding) and progress; the footer shows "Processing file X of N", overall progress, and **Cancel**. Cancelling stops after cleaning up the current file: its original is untouched, files already finished stay finished, and the rest go back to ready.
7. **Failures don't stop the batch:** a file that fails is marked with the reason and the next one starts. At the end the footer summarizes the run (for example "3 files done, 1 failed") with **Show in Finder** for the results. Finished and failed files can be queued again with **Process Again** (context menu).

## Output

- **Toggle on:** each original file is replaced in place as it finishes (atomically, so a failure never leaves a half-written file). Video and all non-audio streams are copied bit-for-bit; only the audio is re-encoded.
- **Toggle off:** each result is saved in the output folder as `<name> (No Speech).<ext>`. If that name is taken, `(No Speech 2)`, `(No Speech 3)`, … is used; existing files are never overwritten.
- Each finished row shows where its file went, with **Show in Finder**.

### Format rules

- The output keeps the input's container (file extension).
- Every audio track is processed. Each is re-encoded with the same codec, sample rate, channel layout, and (for lossy codecs) bitrate when FFmpeg has an encoder for it; otherwise with the container's fallback codec (for example AAC for MP4/MOV/MKV, Opus for WebM, PCM for WAV).
- Video, subtitle, attachment, cover art, chapters, and metadata are copied. If the container refuses a stream when muxing, data streams and then subtitles are dropped, in that order, rather than failing.

## Speech removal

- Speech is estimated by the selected engine and removed from the original mix: `output = mix − speech` (Demucs) or a spectral mask `1 − |speech| / |mix|` applied to the mix (Apple Voice Isolation). Anything the engine does not classify as speech is left as it was.
- Demucs runs on 44.1 kHz stereo segments of 7.8 s with 25% overlap and linear crossfades, as in the reference implementation. Mono tracks are duplicated to stereo; tracks with more than two channels are processed in channel pairs.
- Apple Voice Isolation processes each channel separately.

## Non-goals (for now)

- Processing several files at the same time (a batch runs one file after another).
- Preview playback or before/after comparison.
- Partial removal (strength slider) or keeping speech and removing everything else.
- Signing, notarization, and distribution builds.
