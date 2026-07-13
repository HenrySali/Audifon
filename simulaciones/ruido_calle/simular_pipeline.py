"""
Simulación del pipeline DSP completo en Python.

Replica la cadena del motor C++ (dsp_pipeline.h):
  HPF 100Hz → NR (Wiener) → EQ 12 bandas → WDRC → Volume → MPO

NO usa el GTCRN real (requiere OnnxRuntime + modelo). En su lugar simula
el efecto del DNN como un filtro Wiener ideal que conoce la voz limpia
(oracle mask). Esto da el MEJOR CASO posible del filtro de ruido.

Para simular con el GTCRN real, compilar el C++ como CLI (ver README.md).

Entrada: entrada/mezcla_snr0.wav
Salida:  salida/salida_pipeline.wav
"""

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, lfilter, sosfilt, sosfiltfilt
import os

# ─── Parámetros del pipeline (iguales al C++) ─────────────────────────────
SR = 16000
BLOCK_SIZE = 64

# HPF: Butterworth 2do orden @ 100 Hz
HPF_CUTOFF = 100.0

# EQ: 12 bandas con ganancias NAL-NL2 típicas para pérdida moderada
EQ_FREQS = [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000]
# Ganancias típicas para audiograma de pérdida moderada (PTA ~45 dB HL)
EQ_GAINS_DB = [6, 10, 12, 14, 14, 12, 10, 8, 8, 8, 6, 4]

# WDRC
WDRC_EXPANSION_KNEE = 35.0   # dB SPL
WDRC_EXPANSION_RATIO = 2.0
WDRC_COMPRESSION_KNEE = 55.0  # dB SPL
WDRC_COMPRESSION_RATIO = 2.0
WDRC_ATTACK_MS = 5.0
WDRC_RELEASE_MS = 100.0

# Volume
VOLUME_DB = 0.0  # 0 dB = sin cambio (nivel default del paciente)

# MPO
MPO_THRESHOLD_DBSPL = 100.0
SPL_OFFSET = 120.0  # dBFS → dB SPL

# DNN simulation: oracle Wiener mask (ideal case)
DNN_ENABLED = True


def apply_hpf(signal, sr, cutoff):
    """Butterworth 2nd order highpass @ cutoff Hz."""
    sos = butter(2, cutoff / (sr / 2), btype='high', output='sos')
    return sosfilt(sos, signal).astype(np.float32)


def apply_eq(signal, sr, freqs, gains_db):
    """Aplica EQ de 12 bandas (peaking filters simplificados)."""
    output = signal.copy()
    for fc, g_db in zip(freqs, gains_db):
        if g_db == 0 or fc >= sr / 2:
            continue
        # Ganancia lineal
        gain_linear = 10 ** (g_db / 20) - 1.0
        # Bandpass centrado en fc con Q=1.4
        Q = 1.4
        bw = fc / Q
        low = max(fc - bw / 2, 20) / (sr / 2)
        high = min(fc + bw / 2, sr / 2 - 1) / (sr / 2)
        if high <= low:
            continue
        b, a = butter(2, [low, high], btype='band')
        band = lfilter(b, a, signal)
        output = output + gain_linear * band
    return output.astype(np.float32)


def apply_wdrc(signal, sr):
    """WDRC simplificado: expansión + lineal + compresión."""
    # Convertir a dB SPL (simulado)
    output = np.zeros_like(signal)
    envelope = 0.0
    attack_coeff = 1.0 - np.exp(-1.0 / (WDRC_ATTACK_MS * sr / 1000))
    release_coeff = 1.0 - np.exp(-1.0 / (WDRC_RELEASE_MS * sr / 1000))

    for i in range(len(signal)):
        abs_sample = abs(signal[i])
        if abs_sample > envelope:
            envelope += attack_coeff * (abs_sample - envelope)
        else:
            envelope += release_coeff * (abs_sample - envelope)

        # Nivel en dB SPL (simulado con offset)
        level_db = 20 * np.log10(envelope + 1e-10) + SPL_OFFSET

        # Ganancia del WDRC
        if level_db < WDRC_EXPANSION_KNEE:
            # Expansión: atenuar señales débiles
            diff = WDRC_EXPANSION_KNEE - level_db
            gain_db = -diff * (1.0 - 1.0 / WDRC_EXPANSION_RATIO)
        elif level_db > WDRC_COMPRESSION_KNEE:
            # Compresión: atenuar señales fuertes
            diff = level_db - WDRC_COMPRESSION_KNEE
            gain_db = -diff * (1.0 - 1.0 / WDRC_COMPRESSION_RATIO)
        else:
            # Región lineal
            gain_db = 0.0

        gain_linear = 10 ** (gain_db / 20)
        output[i] = signal[i] * gain_linear

    return output.astype(np.float32)


def apply_volume(signal, volume_db):
    """Aplica volumen maestro en dB."""
    return (signal * 10 ** (volume_db / 20)).astype(np.float32)


def apply_mpo(signal):
    """MPO: hard-limit al threshold."""
    threshold_linear = 10 ** ((MPO_THRESHOLD_DBSPL - SPL_OFFSET) / 20)
    threshold_linear = min(threshold_linear, 0.85)  # Techo digital
    return np.clip(signal, -threshold_linear, threshold_linear).astype(np.float32)


def apply_dnn_oracle(mezcla, voz_limpia):
    """
    Simula el DNN GTCRN con una máscara Wiener oracle (caso ideal).
    En la realidad, el DNN estima esta máscara sin conocer la voz limpia.
    """
    # STFT
    frame_len = 512
    hop = 160
    window = np.hanning(frame_len)

    # Pad
    pad_len = frame_len - len(mezcla) % hop
    mezcla_pad = np.concatenate([mezcla, np.zeros(pad_len)])
    voz_pad = np.concatenate([voz_limpia, np.zeros(pad_len)])

    n_frames = (len(mezcla_pad) - frame_len) // hop + 1
    output = np.zeros_like(mezcla_pad)
    win_sum = np.zeros_like(mezcla_pad)

    for i in range(n_frames):
        start = i * hop
        frame_mix = mezcla_pad[start:start + frame_len] * window
        frame_voz = voz_pad[start:start + frame_len] * window

        # FFT
        X_mix = np.fft.rfft(frame_mix)
        X_voz = np.fft.rfft(frame_voz)

        # Máscara Wiener oracle: |S|^2 / (|S|^2 + |N|^2)
        power_voz = np.abs(X_voz) ** 2
        power_mix = np.abs(X_mix) ** 2
        mask = power_voz / (power_mix + 1e-10)
        mask = np.clip(mask, 0, 1)

        # Aplicar máscara
        X_out = X_mix * mask
        frame_out = np.fft.irfft(X_out, n=frame_len)

        output[start:start + frame_len] += frame_out * window
        win_sum[start:start + frame_len] += window ** 2

    # Normalizar overlap-add
    win_sum[win_sum < 1e-10] = 1e-10
    output = output / win_sum

    return output[:len(mezcla)].astype(np.float32)


def main():
    os.makedirs('salida', exist_ok=True)

    # Leer entrada
    sr_in, mezcla = wavfile.read('entrada/mezcla_snr0.wav')
    _, voz_limpia = wavfile.read('entrada/voz_limpia.wav')
    assert sr_in == SR, f"Sample rate mismatch: {sr_in} vs {SR}"

    mezcla = mezcla.astype(np.float32)
    voz_limpia = voz_limpia.astype(np.float32)

    # Si están en int16, normalizar
    if mezcla.max() > 1.0:
        mezcla = mezcla / 32768.0
        voz_limpia = voz_limpia / 32768.0

    print("═══════════════════════════════════════════════════════")
    print("  SIMULACIÓN DEL PIPELINE DSP — FILTRO DE RUIDO")
    print("═══════════════════════════════════════════════════════")
    print(f"  Entrada: mezcla_snr0.wav ({len(mezcla)/SR:.1f}s, {SR} Hz)")
    print(f"  Pipeline: HPF→DNN→EQ→WDRC→Volume→MPO")
    print()

    # ─── PIPELINE ─────────────────────────────────────────────────────────

    señal = mezcla.copy()
    etapas = {}

    # 1. HPF 100 Hz
    señal = apply_hpf(señal, SR, HPF_CUTOFF)
    etapas['post_hpf'] = señal.copy()
    print(f"  [1] HPF 100 Hz         RMS={20*np.log10(np.sqrt(np.mean(señal**2))+1e-10):.1f} dBFS")

    # 2. DNN (oracle Wiener mask)
    if DNN_ENABLED:
        señal = apply_dnn_oracle(señal, apply_hpf(voz_limpia, SR, HPF_CUTOFF))
        etapas['post_dnn'] = señal.copy()
        print(f"  [2] DNN (oracle mask)  RMS={20*np.log10(np.sqrt(np.mean(señal**2))+1e-10):.1f} dBFS")
    else:
        etapas['post_dnn'] = señal.copy()
        print(f"  [2] DNN (bypassed)")

    # 3. EQ 12 bandas
    señal = apply_eq(señal, SR, EQ_FREQS, EQ_GAINS_DB)
    etapas['post_eq'] = señal.copy()
    print(f"  [3] EQ 12 bandas       RMS={20*np.log10(np.sqrt(np.mean(señal**2))+1e-10):.1f} dBFS")

    # 4. WDRC
    señal = apply_wdrc(señal, SR)
    etapas['post_wdrc'] = señal.copy()
    print(f"  [4] WDRC               RMS={20*np.log10(np.sqrt(np.mean(señal**2))+1e-10):.1f} dBFS")

    # 5. Volume
    señal = apply_volume(señal, VOLUME_DB)
    etapas['post_vol'] = señal.copy()
    print(f"  [5] Volume ({VOLUME_DB:+.0f} dB)     RMS={20*np.log10(np.sqrt(np.mean(señal**2))+1e-10):.1f} dBFS")

    # 6. MPO
    señal = apply_mpo(señal)
    etapas['post_mpo'] = señal.copy()
    print(f"  [6] MPO ({MPO_THRESHOLD_DBSPL:.0f} dB SPL)  RMS={20*np.log10(np.sqrt(np.mean(señal**2))+1e-10):.1f} dBFS")

    print()

    # ─── MÉTRICAS DE SALIDA ───────────────────────────────────────────────

    # SNR de salida (comparando con voz limpia procesada sin ruido)
    voz_ref = apply_hpf(voz_limpia, SR, HPF_CUTOFF)
    voz_ref = apply_eq(voz_ref, SR, EQ_FREQS, EQ_GAINS_DB)
    # No WDRC/MPO en la referencia (solo queremos medir cuánto ruido queda)

    noise_residual = señal - voz_ref[:len(señal)]
    snr_out = 10 * np.log10(
        np.mean(voz_ref[:len(señal)] ** 2) /
        (np.mean(noise_residual ** 2) + 1e-10)
    )

    print(f"  ─── RESULTADOS ───")
    print(f"  SNR entrada:  0.0 dB")
    print(f"  SNR salida:   {snr_out:.1f} dB")
    print(f"  Mejora SNR:   {snr_out:.1f} dB")
    print()

    # Guardar salida
    wavfile.write('salida/salida_pipeline.wav', SR, señal)
    print(f"  Salida guardada: salida/salida_pipeline.wav")

    # Guardar etapas intermedias para las gráficas
    for nombre, data in etapas.items():
        wavfile.write(f'salida/{nombre}.wav', SR, data)

    print("  Etapas intermedias guardadas en salida/")
    print("═══════════════════════════════════════════════════════")


if __name__ == '__main__':
    main()
