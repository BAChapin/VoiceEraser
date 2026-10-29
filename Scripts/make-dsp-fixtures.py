#!/usr/bin/env python3
"""Writes VoiceEraserKit/Tests/VoiceEraserKitTests/Fixtures/dsp-fixtures.json.

The Swift STFT, iSTFT and Demucs spectrogram code must match PyTorch and
demucs exactly, because the Core ML model was trained on PyTorch's
spectrograms. These fixtures are computed with the reference implementations
at small sizes; the Swift tests compare against them.

Needs torch and demucs (Scripts/requirements.txt). Deterministic: rerunning
produces the same file.
"""

import json
import math
from pathlib import Path

import torch
import torch.nn.functional as F

from demucs.hdemucs import pad1d
from demucs.spec import ispectro, spectro

OUTPUT = Path(__file__).resolve().parent.parent / "VoiceEraserKit/Tests/VoiceEraserKitTests/Fixtures/dsp-fixtures.json"


def demucs_spec(x, nfft, hl):
    """HTDemucs._spec with configurable sizes."""
    le = int(math.ceil(x.shape[-1] / hl))
    pad = hl // 2 * 3
    x = pad1d(x, (pad, pad + le * hl - x.shape[-1]), mode="reflect")
    z = spectro(x, nfft, hl)[..., :-1, :]
    return z[..., 2: 2 + le]


def demucs_ispec(z, length, hl):
    """HTDemucs._ispec with configurable sizes."""
    z = F.pad(z, (0, 0, 0, 1))
    z = F.pad(z, (2, 2))
    pad = hl // 2 * 3
    le = hl * int(math.ceil(length / hl)) + 2 * pad
    x = ispectro(z, hl, length=le)
    return x[..., pad: pad + length]


def flat(t):
    return [round(float(v), 8) for v in t.reshape(-1).tolist()]


def main():
    g = torch.Generator().manual_seed(1234)
    fixtures = {}

    nfft, hop, length = 16, 4, 50
    signal = torch.randn(length, generator=g, dtype=torch.float64)
    window = torch.hann_window(nfft, dtype=torch.float64)
    z = torch.stft(signal, nfft, hop, window=window, win_length=nfft, normalized=True,
                   center=True, return_complex=True, pad_mode="reflect")
    noise = torch.randn(z.shape, generator=g, dtype=torch.float64) + 1j * torch.randn(z.shape, generator=g, dtype=torch.float64)
    istft = torch.istft(noise, nfft, hop, window=window, win_length=nfft, normalized=True, center=True, length=length)
    fixtures["stft"] = {
        "fftSize": nfft, "hopSize": hop, "signal": flat(signal),
        "bins": z.shape[0], "frames": z.shape[1], "real": flat(z.real), "imag": flat(z.imag),
        "inverseInputReal": flat(noise.real), "inverseInputImag": flat(noise.imag),
        "inverseLength": length, "inverse": flat(istft),
    }

    nfft, hop, length = 64, 16, 150
    signal = torch.randn(length, generator=g, dtype=torch.float64)
    # Reflect padding needs a channel dimension.
    z = demucs_spec(signal[None], nfft, hop)[0]
    noise = torch.randn(z.shape, generator=g, dtype=torch.float64) + 1j * torch.randn(z.shape, generator=g, dtype=torch.float64)
    ispec = demucs_ispec(noise[None], length, hop)[0]
    fixtures["demucs"] = {
        "fftSize": nfft, "hopSize": hop, "signal": flat(signal),
        "bins": z.shape[0], "frames": z.shape[1], "real": flat(z.real), "imag": flat(z.imag),
        "inverseInputReal": flat(noise.real), "inverseInputImag": flat(noise.imag),
        "inverseLength": length, "inverse": flat(ispec),
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixtures, separators=(",", ":")) + "\n")
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
