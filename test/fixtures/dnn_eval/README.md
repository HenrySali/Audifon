# DSP Quality Evaluation Fixtures

## Purpose

These synthetic WAV files are used by the CI workflow `dsp-quality.yml` to validate
that the DNN denoiser pipeline doesn't regress in quality (PESQ/STOI).

## Scenarios

| File | Noise type | SNR | Simulates |
|------|-----------|-----|-----------|
| `voice_white_5dB` | White (Gaussian) | 5 dB | Indoor appliance / fan noise |
| `voice_white_10dB` | White (Gaussian) | 10 dB | Light background noise |
| `voice_pink_5dB` | Pink (1/f) | 5 dB | Street traffic / environment |
| `voice_babble_0dB` | Babble (6 speakers) | 0 dB | Crowded restaurant / subway |
| `voice_babble_5dB` | Babble (6 speakers) | 5 dB | Office with multiple talkers |

## Format

- Sample rate: 16 kHz
- Channels: mono
- Bit depth: 16-bit PCM
- Duration: 3 seconds each

## Generation

Generated with numpy using harmonic synthesis + amplitude modulation at syllable rate.
See the generation script in the commit message or run:

```python
# From project root
python3 scripts/generate_eval_fixtures.py
```

## Upgrading to real recordings

For more accurate regression testing, replace these synthetic files with
real recordings from the Moto G32 diagnostic WAVs (extracted via adb).
Keep the same filename convention and ensure 16 kHz mono PCM.
