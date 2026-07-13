#!/usr/bin/env python3
"""
Generate synthetic WAV fixtures for DSP quality regression testing.

Usage:
    python3 scripts/generate_eval_fixtures.py

Output:
    test/fixtures/dnn_eval/clean/*.wav
    test/fixtures/dnn_eval/noisy/*.wav
"""
import numpy as np
import soundfile as sf
import os

SR = 16000
DURATION = 3.0
N = int(SR * DURATION)

CLEAN_DIR = "test/fixtures/dnn_eval/clean"
NOISY_DIR = "test/fixtures/dnn_eval/noisy"

np.random.seed(42)


def generate_speech_like(n, sr):
    """Simulate speech: sum of harmonics with amplitude modulation."""
    t = np.arange(n) / sr
    f0 = 120  # male voice fundamental
    signal = np.zeros(n)
    for h in range(1, 8):
        signal += (1.0 / h) * np.sin(2 * np.pi * f0 * h * t)
    envelope = 0.5 + 0.5 * np.sin(2 * np.pi * 4.0 * t)
    signal *= envelope
    signal = signal / np.max(np.abs(signal)) * 0.1
    return signal


def generate_noise(n, noise_type="white"):
    """Generate noise: white, pink, or babble-like."""
    if noise_type == "white":
        return np.random.randn(n)
    elif noise_type == "pink":
        white = np.random.randn(n)
        freqs = np.fft.rfftfreq(n)
        freqs[0] = 1
        fft = np.fft.rfft(white)
        fft /= np.sqrt(freqs)
        return np.fft.irfft(fft, n)
    elif noise_type == "babble":
        babble = np.zeros(n)
        for _ in range(6):
            f0 = np.random.uniform(100, 250)
            t = np.arange(n) / SR
            voice = np.zeros(n)
            for h in range(1, 5):
                voice += (1.0 / h) * np.sin(
                    2 * np.pi * f0 * h * t + np.random.uniform(0, 2 * np.pi)
                )
            env = 0.5 + 0.5 * np.sin(
                2 * np.pi * np.random.uniform(2, 6) * t
                + np.random.uniform(0, 2 * np.pi)
            )
            babble += voice * env
        return babble
    return np.random.randn(n)


def mix_at_snr(clean, noise, snr_db):
    """Mix clean signal with noise at specified SNR."""
    clean_power = np.mean(clean**2)
    noise_power = np.mean(noise**2)
    if noise_power == 0:
        return clean
    scale = np.sqrt(clean_power / (noise_power * 10 ** (snr_db / 10)))
    mixed = clean + noise * scale
    peak = np.max(np.abs(mixed))
    if peak > 0.95:
        mixed = mixed / peak * 0.95
    return mixed


scenarios = [
    {"name": "voice_white_5dB", "noise_type": "white", "snr": 5},
    {"name": "voice_white_10dB", "noise_type": "white", "snr": 10},
    {"name": "voice_pink_5dB", "noise_type": "pink", "snr": 5},
    {"name": "voice_babble_0dB", "noise_type": "babble", "snr": 0},
    {"name": "voice_babble_5dB", "noise_type": "babble", "snr": 5},
]

if __name__ == "__main__":
    os.makedirs(CLEAN_DIR, exist_ok=True)
    os.makedirs(NOISY_DIR, exist_ok=True)

    for scenario in scenarios:
        name = scenario["name"]
        clean = generate_speech_like(N, SR)
        noise = generate_noise(N, scenario["noise_type"])
        noisy = mix_at_snr(clean, noise, scenario["snr"])

        sf.write(
            os.path.join(CLEAN_DIR, f"{name}.wav"),
            clean.astype(np.float32),
            SR,
            subtype="PCM_16",
        )
        sf.write(
            os.path.join(NOISY_DIR, f"{name}.wav"),
            noisy.astype(np.float32),
            SR,
            subtype="PCM_16",
        )
        print(f"  {name}: SNR={scenario['snr']} dB")

    print(f"\nGenerated {len(scenarios)} pairs in {CLEAN_DIR}/ and {NOISY_DIR}/")
