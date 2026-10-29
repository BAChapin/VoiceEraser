#!/usr/bin/env python3
"""Converts the Demucs vocals model to Core ML for VoiceEraser.

The model is the vocals specialist from Meta's `htdemucs_ft` bag (Hybrid
Transformer Demucs v4, MIT license, https://github.com/facebookresearch/demucs).
Only the neural network is converted. The STFT/iSTFT around it run in Swift
(VoiceEraserKit/Sources/VoiceEraserKit/DSP/DemucsSpectrogram.swift), because
Core ML has no complex tensors.

Core ML model contract (one 7.8 s segment, 44.1 kHz stereo):
  inputs
    mix          float32 [1, 2, 343980]      waveform segment
    spec         float32 [1, 4, 2048, 336]   STFT of `mix` as HTDemucs._spec
                                             computes it, complex-as-channels:
                                             [L.re, L.im, R.re, R.im]
  outputs
    vocals_spec  float32 [1, 4, 2048, 336]   vocals spectrogram, same layout
    vocals_wave  float32 [1, 2, 343980]      vocals time-branch waveform
  vocals = iSTFT(vocals_spec) + vocals_wave

Usage:
  convert-model.py [--output PATH] [--reference-dir DIR] [--random-weights]
                   [--skip-coreml-check]

--reference-dir writes reference-mix.f32 and reference-vocals.f32 (planar
float32, 2 x 343980): a test segment and the vocals PyTorch separates from
it. VoiceEraserKit's tests check the Swift side against them.

--random-weights builds an untrained HTDemucs (no download) to test the
conversion itself. On macOS the converted model is run once and compared with
PyTorch; elsewhere that check is skipped (Core ML can't run there).
"""

import argparse
import math
import platform
import sys
from fractions import Fraction
from pathlib import Path

import numpy as np
import torch
from einops import rearrange

SEGMENT_SAMPLES = 343980  # int(7.8 s * 44100 Hz), the model's training length
VOCALS_SIGNATURE = "04573f0d"  # htdemucs_ft member whose bag weight is vocals-only
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "VoiceEraser" / "Resources" / "Models" / "HTDemucsVocals.mlpackage"


class VocalsCore(torch.nn.Module):
    """HTDemucs.forward without the STFT, iSTFT and complex masking, returning
    only the vocals source. Mirrors demucs/htdemucs.py (demucs 4.0.1)."""

    def __init__(self, model, source_index):
        super().__init__()
        self.model = model
        self.source_index = source_index

    def forward(self, mix, spec):
        m = self.model
        x = spec
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)

        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_downsampler_t(xt)

        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]
        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]
        return x[:, self.source_index], xt[:, self.source_index]


def load_model(random_weights):
    from demucs.htdemucs import HTDemucs

    if random_weights:
        torch.manual_seed(0)
        model = HTDemucs(sources=["drums", "bass", "other", "vocals"], segment=Fraction(39, 5))
    else:
        from demucs.apply import BagOfModels
        from demucs.pretrained import get_model

        model = get_model(VOCALS_SIGNATURE)
        if isinstance(model, BagOfModels):
            model = model.models[0]
    model.eval()
    assert isinstance(model, HTDemucs), type(model)
    assert model.cac and model.use_train_segment and model.nfft == 4096 and model.hop_length == 1024
    assert int(model.segment * model.samplerate) == SEGMENT_SAMPLES, model.segment
    assert model.samplerate == 44100 and model.audio_channels == 2
    return model


def reference_spec(model, mix):
    """The `spec` input exactly as HTDemucs computes it internally."""
    return model._magnitude(model._spec(mix))


def check_core_matches_model(model, core, source_index):
    """The wrapper plus a PyTorch iSTFT must reproduce HTDemucs.forward."""
    torch.manual_seed(1)
    mix = torch.randn(1, 2, SEGMENT_SAMPLES) * 0.1
    with torch.no_grad():
        expected = model(mix)[:, source_index]
        spec_out, wave_out = core(mix, reference_spec(model, mix))
        zout = model._mask(None, spec_out[:, None])[:, 0]
        actual = model._ispec(zout, SEGMENT_SAMPLES) + wave_out
    error = (expected - actual).abs().max().item()
    scale = expected.abs().max().item()
    print(f"wrapper vs HTDemucs.forward: max abs error {error:.3e} (signal peak {scale:.3e})")
    if error > 1e-4 * max(scale, 1e-3):
        sys.exit("error: wrapper output differs from HTDemucs.forward")
    return mix


def convert(core, mix, spec, output):
    import coremltools as ct

    with torch.no_grad():
        traced = torch.jit.trace(core, (mix, spec), check_trace=False)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="mix", shape=tuple(mix.shape), dtype=np.float32),
            ct.TensorType(name="spec", shape=tuple(spec.shape), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="vocals_spec", dtype=np.float32),
            ct.TensorType(name="vocals_wave", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS15,
        # fp16 measured 23 dB SNR against PyTorch on the vocals spectrogram;
        # fp32 keeps the High Quality engine faithful (runs on GPU/CPU).
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = "Hybrid Transformer Demucs (htdemucs_ft vocals) without STFT, for VoiceEraser."
    mlmodel.author = "Meta AI Research (Demucs, MIT License); converted for VoiceEraser"
    mlmodel.license = "MIT"
    mlmodel.version = "htdemucs_ft-" + VOCALS_SIGNATURE
    output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output))
    print(f"saved {output}")
    return mlmodel


def check_coreml(mlmodel, core, mix, spec):
    """Runs the converted model and compares it with PyTorch (macOS only)."""
    failures = []
    with torch.no_grad():
        ref_spec, ref_wave = core(mix, spec)
    result = mlmodel.predict({"mix": mix.numpy(), "spec": spec.numpy()})
    for name, ref in (("vocals_spec", ref_spec), ("vocals_wave", ref_wave)):
        got = result[name]
        ref = ref.numpy()
        snr = 10 * math.log10(float((ref**2).sum()) / max(float(((ref - got) ** 2).sum()), 1e-20))
        print(f"Core ML vs PyTorch {name}: SNR {snr:.1f} dB")
        if snr < 40:
            failures.append(f"{name} SNR {snr:.1f} dB < 40 dB")
    if failures:
        sys.exit("error: Core ML deviates from PyTorch: " + "; ".join(failures))


def write_reference(model, core, mix, spec, directory):
    """Saves a segment and its PyTorch vocals for the Swift glue test."""
    with torch.no_grad():
        spec_out, wave_out = core(mix, spec)
        zout = model._mask(None, spec_out[:, None])[:, 0]
        vocals = model._ispec(zout, SEGMENT_SAMPLES) + wave_out
    directory.mkdir(parents=True, exist_ok=True)
    mix[0].numpy().astype("<f4").tofile(directory / "reference-mix.f32")
    vocals[0].numpy().astype("<f4").tofile(directory / "reference-vocals.f32")
    print(f"wrote reference segment to {directory}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--reference-dir", type=Path)
    parser.add_argument("--random-weights", action="store_true")
    parser.add_argument("--skip-coreml-check", action="store_true")
    args = parser.parse_args()

    torch.backends.mha.set_fastpath_enabled(False)
    model = load_model(args.random_weights)
    source_index = model.sources.index("vocals")
    core = VocalsCore(model, source_index).eval()

    mix = check_core_matches_model(model, core, source_index)
    with torch.no_grad():
        spec = reference_spec(model, mix)
    mlmodel = convert(core, mix, spec, args.output)
    if args.reference_dir:
        write_reference(model, core, mix, spec, args.reference_dir)

    if platform.system() == "Darwin" and not args.skip_coreml_check:
        check_coreml(mlmodel, core, mix, spec)
    else:
        print("skipping Core ML prediction check (needs macOS)")


if __name__ == "__main__":
    main()
