"""
Genera gráficas de la simulación: entrada, proceso y salida.

Salidas:
  - graficas/01_entrada_temporal.png
  - graficas/02_entrada_espectro.png
  - graficas/03_pipeline_etapas.png
  - graficas/04_salida_vs_entrada.png
  - graficas/05_espectro_comparativo.png
"""

import numpy as np
from scipy.io import wavfile
from scipy.signal import welch
import matplotlib
matplotlib.use('Agg')  # Sin GUI
import matplotlib.pyplot as plt
import os


def load_wav(path):
    sr, data = wavfile.read(path)
    data = data.astype(np.float32)
    if data.max() > 1.0:
        data = data / 32768.0
    return sr, data


def plot_temporal(ax, signal, sr, title, color='blue'):
    t = np.arange(len(signal)) / sr
    ax.plot(t, signal, color=color, linewidth=0.3)
    ax.set_title(title, fontsize=10, fontweight='bold')
    ax.set_xlabel('Tiempo (s)')
    ax.set_ylabel('Amplitud')
    ax.set_ylim(-1, 1)
    ax.grid(True, alpha=0.3)


def plot_spectrum(ax, signal, sr, title, color='blue', label=None):
    f, Pxx = welch(signal, sr, nperseg=1024)
    ax.semilogy(f, Pxx, color=color, linewidth=1, label=label)
    ax.set_title(title, fontsize=10, fontweight='bold')
    ax.set_xlabel('Frecuencia (Hz)')
    ax.set_ylabel('PSD (V²/Hz)')
    ax.set_xlim(0, 8000)
    ax.grid(True, alpha=0.3)
    if label:
        ax.legend(fontsize=8)


def main():
    os.makedirs('graficas', exist_ok=True)

    # Cargar archivos
    sr, voz = load_wav('entrada/voz_limpia.wav')
    _, ruido = load_wav('entrada/ruido_calle.wav')
    _, mezcla = load_wav('entrada/mezcla_snr0.wav')
    _, salida = load_wav('salida/salida_pipeline.wav')
    _, post_hpf = load_wav('salida/post_hpf.wav')
    _, post_dnn = load_wav('salida/post_dnn.wav')
    _, post_eq = load_wav('salida/post_eq.wav')
    _, post_wdrc = load_wav('salida/post_wdrc.wav')
    _, post_mpo = load_wav('salida/post_mpo.wav')

    # ─── Gráfica 1: Señales de entrada (temporal) ─────────────────────────
    fig, axes = plt.subplots(3, 1, figsize=(12, 8))
    fig.suptitle('ENTRADA: Señales Temporales', fontsize=14, fontweight='bold')
    plot_temporal(axes[0], voz, sr, 'Voz limpia (150 Hz + formantes)', 'green')
    plot_temporal(axes[1], ruido, sr, 'Ruido de calle (50-2500 Hz)', 'red')
    plot_temporal(axes[2], mezcla, sr, 'Mezcla (SNR = 0 dB)', 'purple')
    plt.tight_layout()
    plt.savefig('graficas/01_entrada_temporal.png', dpi=150)
    plt.close()
    print("  ✓ graficas/01_entrada_temporal.png")

    # ─── Gráfica 2: Espectros de entrada ──────────────────────────────────
    fig, ax = plt.subplots(1, 1, figsize=(12, 5))
    fig.suptitle('ENTRADA: Espectro de Potencia', fontsize=14, fontweight='bold')
    plot_spectrum(ax, voz, sr, '', 'green', 'Voz limpia')
    plot_spectrum(ax, ruido, sr, '', 'red', 'Ruido de calle')
    plot_spectrum(ax, mezcla, sr, '', 'purple', 'Mezcla SNR=0dB')
    ax.legend(fontsize=10)
    ax.set_title('Densidad espectral de potencia (PSD)')
    plt.tight_layout()
    plt.savefig('graficas/02_entrada_espectro.png', dpi=150)
    plt.close()
    print("  ✓ graficas/02_entrada_espectro.png")

    # ─── Gráfica 3: Etapas del pipeline ───────────────────────────────────
    fig, axes = plt.subplots(6, 1, figsize=(12, 14))
    fig.suptitle('PROCESO: Señal en cada etapa del pipeline DSP',
                 fontsize=14, fontweight='bold')
    etapas = [
        (mezcla, 'Entrada (mezcla)', 'purple'),
        (post_hpf, '[1] Post-HPF (100 Hz)', 'blue'),
        (post_dnn, '[2] Post-DNN (ruido atenuado)', 'teal'),
        (post_eq, '[3] Post-EQ (12 bandas NAL-NL2)', 'orange'),
        (post_wdrc, '[4] Post-WDRC (compresión)', 'brown'),
        (post_mpo, '[5-6] Post-Volume+MPO (salida final)', 'green'),
    ]
    for ax, (sig, title, color) in zip(axes, etapas):
        plot_temporal(ax, sig, sr, title, color)
    plt.tight_layout()
    plt.savefig('graficas/03_pipeline_etapas.png', dpi=150)
    plt.close()
    print("  ✓ graficas/03_pipeline_etapas.png")

    # ─── Gráfica 4: Salida vs Entrada ─────────────────────────────────────
    fig, axes = plt.subplots(3, 1, figsize=(12, 8))
    fig.suptitle('RESULTADO: Comparación entrada → salida',
                 fontsize=14, fontweight='bold')
    plot_temporal(axes[0], mezcla, sr, 'Entrada: mezcla (voz + ruido calle)', 'purple')
    plot_temporal(axes[1], salida, sr, 'Salida: lo que escucha el paciente', 'green')
    plot_temporal(axes[2], voz, sr, 'Referencia: voz limpia original', 'gray')
    plt.tight_layout()
    plt.savefig('graficas/04_salida_vs_entrada.png', dpi=150)
    plt.close()
    print("  ✓ graficas/04_salida_vs_entrada.png")

    # ─── Gráfica 5: Espectro comparativo ──────────────────────────────────
    fig, ax = plt.subplots(1, 1, figsize=(12, 5))
    fig.suptitle('RESULTADO: Espectro — Entrada vs Salida',
                 fontsize=14, fontweight='bold')
    plot_spectrum(ax, mezcla, sr, '', 'purple', 'Entrada (mezcla)')
    plot_spectrum(ax, salida, sr, '', 'green', 'Salida (pipeline completo)')
    plot_spectrum(ax, voz, sr, '', 'gray', 'Voz limpia (referencia)')
    ax.legend(fontsize=10)
    ax.set_title('¿La salida se parece más a la voz que a la mezcla?')
    plt.tight_layout()
    plt.savefig('graficas/05_espectro_comparativo.png', dpi=150)
    plt.close()
    print("  ✓ graficas/05_espectro_comparativo.png")

    print("\n  Todas las gráficas generadas en graficas/")


if __name__ == '__main__':
    main()
