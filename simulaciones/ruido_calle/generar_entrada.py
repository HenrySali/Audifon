"""
Generador de señal de entrada para simulación de filtro de ruido.

Genera:
  1. Voz sintética (tono fundamental 150 Hz + formantes F1-F4)
  2. Ruido de calle (banda 50-2500 Hz, componentes de motor + rodadura)
  3. Mezcla a SNR controlado (default: 0 dB — misma energía voz y ruido)

Salidas:
  - entrada/voz_limpia.wav
  - entrada/ruido_calle.wav
  - entrada/mezcla_snr0.wav
"""

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, lfilter
import os

# ─── Parámetros ───────────────────────────────────────────────────────────
SR = 16000          # Sample rate (igual que el motor DSP)
DURACION = 3.0      # Segundos
SNR_DB = 0.0        # Signal-to-noise ratio de la mezcla

# Frecuencias de formantes de vocal /a/ (voz masculina adulta)
F0 = 150            # Fundamental de la voz
FORMANTES = [730, 1090, 2440, 3400]  # F1, F2, F3, F4
ANCHOS_BW = [90, 110, 170, 250]      # Ancho de banda de cada formante

# Ruido de calle: bandas
RUIDO_MOTOR_BAND = (50, 500)      # Motor de vehículos
RUIDO_RODADURA_BAND = (500, 2500) # Tire-road noise


def generar_voz_sintetica(duracion, sr):
    """Genera voz sintética: glottal pulse train + filtro de formantes."""
    t = np.arange(int(sr * duracion)) / sr

    # Tren de pulsos glotales (aproximación: onda de relajación)
    fase = (t * F0) % 1.0
    glottal = 0.5 * (1 - np.cos(2 * np.pi * fase)) * np.exp(-3 * fase)

    # Filtrar por formantes (resonadores de 2do orden en serie)
    señal = glottal.copy()
    for fc, bw in zip(FORMANTES, ANCHOS_BW):
        # Bandpass alrededor del formante
        low = max(fc - bw, 20) / (sr / 2)
        high = min(fc + bw, sr / 2 - 1) / (sr / 2)
        if high <= low:
            continue
        b, a = butter(2, [low, high], btype='band')
        componente = lfilter(b, a, glottal)
        señal = señal + 0.5 * componente

    # Modular amplitud (simular sílabas: on 200ms, off 100ms)
    envelope = np.zeros_like(t)
    periodo_silaba = 0.3  # 300 ms por sílaba
    for i in range(int(duracion / periodo_silaba)):
        inicio = int(i * periodo_silaba * sr)
        fin_on = int((i * periodo_silaba + 0.2) * sr)
        if fin_on > len(envelope):
            break
        # Ramp up/down suave
        n_on = fin_on - inicio
        envelope[inicio:fin_on] = np.hanning(n_on * 2)[:n_on]

    señal = señal * envelope

    # Normalizar a pico 0.7
    señal = señal / (np.max(np.abs(señal)) + 1e-10) * 0.7
    return señal.astype(np.float32)


def generar_ruido_calle(duracion, sr):
    """Genera ruido de calle: broadband filtrado a bandas de tráfico."""
    n = int(sr * duracion)
    ruido_blanco = np.random.randn(n)

    # Componente 1: motor (50-500 Hz)
    low = RUIDO_MOTOR_BAND[0] / (sr / 2)
    high = RUIDO_MOTOR_BAND[1] / (sr / 2)
    b, a = butter(4, [low, high], btype='band')
    motor = lfilter(b, a, ruido_blanco) * 1.0

    # Componente 2: rodadura (500-2500 Hz)
    low2 = RUIDO_RODADURA_BAND[0] / (sr / 2)
    high2 = RUIDO_RODADURA_BAND[1] / (sr / 2)
    b2, a2 = butter(4, [low2, high2], btype='band')
    rodadura = lfilter(b2, a2, ruido_blanco) * 0.6

    ruido = motor + rodadura

    # Normalizar a pico 0.7
    ruido = ruido / (np.max(np.abs(ruido)) + 1e-10) * 0.7
    return ruido.astype(np.float32)


def mezclar_snr(voz, ruido, snr_db):
    """Mezcla voz + ruido al SNR especificado (dB)."""
    # Energía RMS
    rms_voz = np.sqrt(np.mean(voz ** 2)) + 1e-10
    rms_ruido = np.sqrt(np.mean(ruido ** 2)) + 1e-10

    # Factor para ajustar ruido al SNR deseado
    factor = rms_voz / (rms_ruido * 10 ** (snr_db / 20))
    ruido_ajustado = ruido * factor

    mezcla = voz + ruido_ajustado

    # Clamp a [-1, 1]
    pico = np.max(np.abs(mezcla))
    if pico > 1.0:
        mezcla = mezcla / pico * 0.95

    return mezcla.astype(np.float32)


def main():
    os.makedirs('entrada', exist_ok=True)

    print(f"Generando señales ({DURACION}s, {SR} Hz, SNR={SNR_DB} dB)...")

    voz = generar_voz_sintetica(DURACION, SR)
    ruido = generar_ruido_calle(DURACION, SR)
    mezcla = mezclar_snr(voz, ruido, SNR_DB)

    # Guardar como WAV float32 (formato que lee el motor C++)
    wavfile.write('entrada/voz_limpia.wav', SR, voz)
    wavfile.write('entrada/ruido_calle.wav', SR, ruido)
    wavfile.write('entrada/mezcla_snr0.wav', SR, mezcla)

    # Métricas de entrada
    rms_voz = 20 * np.log10(np.sqrt(np.mean(voz ** 2)) + 1e-10)
    rms_ruido = 20 * np.log10(np.sqrt(np.mean(ruido ** 2)) + 1e-10)
    rms_mezcla = 20 * np.log10(np.sqrt(np.mean(mezcla ** 2)) + 1e-10)

    print(f"  voz_limpia.wav    RMS={rms_voz:.1f} dBFS")
    print(f"  ruido_calle.wav   RMS={rms_ruido:.1f} dBFS")
    print(f"  mezcla_snr0.wav   RMS={rms_mezcla:.1f} dBFS, SNR={SNR_DB} dB")
    print("Listo.")


if __name__ == '__main__':
    main()
