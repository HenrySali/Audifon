/// @file denoiser_artifact_log.h
/// @brief Registro de sesión de "matraca" (crackle) y calidad para los 3
///        sistemas de limpieza de ruido (RNNoise/DFN3/GTCRN).
///
/// Combina varios `ArtifactMonitor` (artifact_monitor.h) ubicados en taps
/// estratégicos de la cadena de audio para responder tres preguntas:
///
///   1. ¿Hay matraca en la ENTRADA a los sistemas de limpieza? → tap `input_`
///      (señal justo ANTES de que el denoiser activo la procese). Si la
///      matraca ya está acá, la fuente es previa (mic, beamformer, headroom).
///   2. ¿Qué sistema INTRODUCE la matraca? → un tap por cada motor
///      (`engines_[RNNoise|DFN3|GTCRN]`), medido a la SALIDA del sistema.
///      Comparando la tasa de clicks salida vs entrada se atribuye el origen.
///   3. ¿Cómo suena la SALIDA FINAL que escucha el usuario? → tap `output_`
///      (post-DspPipeline completo: WDRC/EQ/MPO/etc.). Mide la calidad final.
///
/// El registro se puede resetear (nueva sesión) y renderizar a un texto
/// copiable (`renderReport()`), pensado para que el técnico/usuario copie el
/// log y lo comparta o analice para resolver el evento de matraca.
///
/// Modelo de hilos: idéntico a ArtifactMonitor. feed*() SOLO desde el hilo de
/// audio; configure()/reset()/renderReport()/summary desde el hilo de control.

#ifndef HEARING_AID_DENOISER_ARTIFACT_LOG_H
#define HEARING_AID_DENOISER_ARTIFACT_LOG_H

#include "artifact_monitor.h"

#include <atomic>
#include <cstdio>
#include <string>

/// Registro de artefactos/calidad de los 3 sistemas de limpieza de ruido.
class DenoiserArtifactLog {
public:
    /// Cantidad de motores de limpieza (RNNoise, DFN3, GTCRN).
    static constexpr int kEngineCount = 3;

    DenoiserArtifactLog() { configure(48000); }

    /// Configura la frecuencia de muestreo de todos los taps y resetea.
    void configure(int sampleRate) {
        sampleRate_ = (sampleRate > 0) ? sampleRate : 48000;
        rawMic_.configure(sampleRate_);
        input_.configure(sampleRate_);
        for (int i = 0; i < kEngineCount; ++i) engines_[i].configure(sampleRate_);
        output_.configure(sampleRate_);
        activeEngineIdx_.store(-1, std::memory_order_relaxed);
    }

    /// Resetea todos los contadores (inicia una nueva sesión de registro).
    void reset() {
        rawMic_.reset();
        input_.reset();
        for (int i = 0; i < kEngineCount; ++i) engines_[i].reset();
        output_.reset();
        activeEngineIdx_.store(-1, std::memory_order_relaxed);
    }

    // ─── Feeds (SOLO hilo de audio) ─────────────────────────────────────

    /// Señal del MICRÓFONO CRUDO, ANTES del realce (MVDR/beamformer) y del
    /// headroom. Permite distinguir si la matraca la genera el micrófono/
    /// fuente o una etapa de realce previa a los sistemas de limpieza.
    void feedRawInput(const float* buf, int n) { rawMic_.feed(buf, n); }

    /// Señal que ENTRA a los sistemas de limpieza (post-realce/headroom,
    /// pre-denoise).
    void feedDenoiserInput(const float* buf, int n) { input_.feed(buf, n); }

    /// Señal a la SALIDA del sistema `engineIdx` (0=RNNoise,1=DFN3,2=GTCRN).
    void feedEngineOutput(int engineIdx, const float* buf, int n) {
        if (engineIdx < 0 || engineIdx >= kEngineCount) return;
        engines_[engineIdx].feed(buf, n);
        activeEngineIdx_.store(engineIdx, std::memory_order_relaxed);
    }

    /// Señal de SALIDA FINAL (lo que escucha el usuario, post-pipeline).
    void feedOutput(const float* buf, int n) { output_.feed(buf, n); }

    // ─── Lecturas (hilo de control) ─────────────────────────────────────

    ArtifactSnapshot rawMicSnapshot() const { return rawMic_.snapshot(); }
    ArtifactSnapshot inputSnapshot()  const { return input_.snapshot(); }
    ArtifactSnapshot outputSnapshot() const { return output_.snapshot(); }
    ArtifactSnapshot engineSnapshot(int i) const {
        return (i >= 0 && i < kEngineCount) ? engines_[i].snapshot()
                                            : ArtifactSnapshot{};
    }
    int activeEngineIndex() const {
        return activeEngineIdx_.load(std::memory_order_relaxed);
    }

    /// Nombre legible del motor por índice.
    static const char* engineName(int i) {
        switch (i) {
            case 0: return "RNNoise (Estandar)";
            case 1: return "DFN3 (Premium)";
            case 2: return "GTCRN (Analitico)";
            default: return "Bypass";
        }
    }

    /// Renderiza el registro completo como texto copiable (hilo de control).
    std::string renderReport() const {
        const ArtifactSnapshot raw = rawMic_.snapshot();
        const ArtifactSnapshot in  = input_.snapshot();
        const ArtifactSnapshot out = output_.snapshot();
        ArtifactSnapshot eng[kEngineCount];
        for (int i = 0; i < kEngineCount; ++i) eng[i] = engines_[i].snapshot();
        const int active = activeEngineIndex();

        std::string r;
        r.reserve(2560);
        char line[320];

        append(r, "==== REGISTRO DE MATRACA / CALIDAD - Sistemas de limpieza de ruido ====\n");
        std::snprintf(line, sizeof(line),
            "Sesion: %.1f s | SR: %d Hz | Motor activo: %s\n\n",
            out.elapsedSec > in.elapsedSec ? out.elapsedSec : in.elapsedSec,
            sampleRate_, engineName(active));
        append(r, line);

        // ─── MICRÓFONO CRUDO (antes del realce) ─────────────────────────
        append(r, "[MICROFONO CRUDO]  (antes del realce MVDR/headroom)\n");
        if (raw.active) {
            appendStage(r, raw);
        } else {
            append(r, "  (sin datos - tap no alimentado)\n");
        }
        append(r, "\n");

        // ─── ENTRADA a los sistemas (post-realce) ───────────────────────
        append(r, "[ENTRADA a los sistemas]  (post-realce MVDR/headroom, pre-limpieza)\n");
        appendStage(r, in);
        append(r, "\n");

        // ─── Cada uno de los 3 sistemas ─────────────────────────────────
        for (int i = 0; i < kEngineCount; ++i) {
            std::snprintf(line, sizeof(line), "[SISTEMA %d - %s]\n",
                          i + 1, engineName(i));
            append(r, line);
            if (!eng[i].active) {
                append(r, "  (inactivo esta sesion / no seleccionado)\n\n");
                continue;
            }
            appendStage(r, eng[i]);

            // Matraca introducida por el sistema (tasa salida - tasa entrada).
            const double deltaRate = eng[i].clicksPerSec - in.clicksPerSec;
            const float  nrDb = in.meanRmsDbfs - eng[i].meanRmsDbfs; // + = atenua
            std::snprintf(line, sizeof(line),
                "  Matraca introducida por el sistema: %+.2f clicks/s | "
                "Reduccion de nivel: %+.1f dB\n",
                deltaRate, nrDb);
            append(r, line);
            std::snprintf(line, sizeof(line),
                "  Peor evento: t=%.1fs, salto=%.3f, calidad=%.0f\n\n",
                eng[i].worstEventSec, eng[i].worstEventJump, eng[i].worstQuality);
            append(r, line);
        }

        // ─── SALIDA FINAL ───────────────────────────────────────────────
        append(r, "[SALIDA FINAL - lo que escucha el usuario]  (post-pipeline)\n");
        appendStage(r, out);
        append(r, "\n");

        // ─── Diagnóstico automático de origen ───────────────────────────
        append(r, "DIAGNOSTICO:\n");
        appendDiagnosis(r, raw, in, eng, out, active);

        return r;
    }

private:
    static void append(std::string& s, const char* txt) { s.append(txt); }

    /// Escribe las líneas comunes de un tap (conteos + niveles + calidad).
    static void appendStage(std::string& r, const ArtifactSnapshot& s) {
        char line[320];
        std::snprintf(line, sizeof(line),
            "  Bloques: %llu | Clicks: %llu (%.2f/s) | Clip: %llu | NaN/Inf: %llu\n",
            static_cast<unsigned long long>(s.blocks),
            static_cast<unsigned long long>(s.clickCount), s.clicksPerSec,
            static_cast<unsigned long long>(s.clipCount),
            static_cast<unsigned long long>(s.nanInfCount));
        r.append(line);
        std::snprintf(line, sizeof(line),
            "  Nivel: RMS %.1f dBFS, pico %.1f dBFS | Salto max: %.3f\n",
            s.meanRmsDbfs, s.lastPeakDbfs, s.maxAbsJump);
        r.append(line);
        std::snprintf(line, sizeof(line),
            "  Calidad: %.0f/100 (peor bloque: %.0f/100)\n",
            s.sessionQuality, s.worstQuality);
        r.append(line);
        std::snprintf(line, sizeof(line),
            "  Aspereza(ronco): %.2f dB modulacion | energia graves: %.0f%%\n",
            s.envFlutterDb, s.lowBandRatio * 100.0f);
        r.append(line);
    }

    /// Heurística de atribución del origen de la matraca.
    static void appendDiagnosis(std::string& r,
                                const ArtifactSnapshot& raw,
                                const ArtifactSnapshot& in,
                                const ArtifactSnapshot eng[kEngineCount],
                                const ArtifactSnapshot& out,
                                int active) {
        char line[320];
        bool any = false;

        // NaN/Inf en cualquier etapa = falla grave prioritaria.
        if (raw.active && raw.nanInfCount > 0) {
            append(r, "  - GRAVE: NaN/Inf en el MICROFONO CRUDO. La fuente (mic/captura) genera fallas numericas.\n");
            any = true;
        }
        if (in.nanInfCount > 0 && !(raw.active && raw.nanInfCount > 0)) {
            append(r, "  - GRAVE: NaN/Inf aparece en la ENTRADA pero no en el mic crudo: lo genera el realce (MVDR/beamformer) o el headroom.\n");
            any = true;
        }
        for (int i = 0; i < kEngineCount; ++i) {
            if (eng[i].active && eng[i].nanInfCount > 0) {
                std::snprintf(line, sizeof(line),
                    "  - GRAVE: NaN/Inf en el SISTEMA %d (%s). El motor produce fallas numericas.\n",
                    i + 1, engineName(i));
                r.append(line);
                any = true;
            }
        }
        if (out.nanInfCount > 0 && (in.nanInfCount == 0)) {
            append(r, "  - GRAVE: NaN/Inf aparece en la SALIDA FINAL pero no en la entrada: lo genera una etapa DSP posterior (WDRC/EQ/MPO).\n");
            any = true;
        }

        // Matraca en el micrófono crudo (fuente real).
        if (raw.active && raw.clicksPerSec >= kNoticeableRate) {
            std::snprintf(line, sizeof(line),
                "  - El MICROFONO/FUENTE ya trae matraca (%.2f clicks/s): el origen es el mic o la captura (revisar mic, BT/USB, underruns). Pasa a traves de todo.\n",
                raw.clicksPerSec);
            r.append(line);
            any = true;
        }

        // Matraca introducida por el realce (MVDR/headroom): aparece en la
        // entrada a los sistemas pero no (o mucho menos) en el mic crudo.
        if (raw.active && in.clicksPerSec - raw.clicksPerSec >= kIntroRate) {
            std::snprintf(line, sizeof(line),
                "  - El REALCE PREVIO (MVDR/beamformer) o el HEADROOM introduce matraca (+%.2f clicks/s sobre el mic crudo) ANTES de los sistemas de limpieza.\n",
                in.clicksPerSec - raw.clicksPerSec);
            r.append(line);
            any = true;
        } else if (!raw.active && in.clicksPerSec >= kNoticeableRate) {
            // Sin tap de mic crudo: no se puede separar mic vs realce.
            std::snprintf(line, sizeof(line),
                "  - La ENTRADA a los sistemas trae matraca (%.2f clicks/s) de una etapa previa (mic/realce/headroom) y pasa a traves.\n",
                in.clicksPerSec);
            r.append(line);
            any = true;
        }

        // Atribución por sistema.
        for (int i = 0; i < kEngineCount; ++i) {
            if (!eng[i].active) continue;
            const double delta = eng[i].clicksPerSec - in.clicksPerSec;
            if (delta >= kIntroRate) {
                std::snprintf(line, sizeof(line),
                    "  - El SISTEMA %d (%s) INTRODUCE matraca (+%.2f clicks/s sobre la entrada). Origen probable: el sistema. Probar bajar intensidad o cambiar de motor.\n",
                    i + 1, engineName(i), delta);
                r.append(line);
                any = true;
            } else if (in.clicksPerSec >= kNoticeableRate && delta > -kIntroRate) {
                std::snprintf(line, sizeof(line),
                    "  - El SISTEMA %d (%s) NO reduce la matraca de la fuente (pasa a traves).\n",
                    i + 1, engineName(i));
                r.append(line);
                any = true;
            }
        }

        // Aspereza / ruido musical ("ronco") introducido por un sistema.
        // Se compara contra la etapa previa real (mic crudo si está, si no
        // la entrada a los sistemas).
        const ArtifactSnapshot& base = raw.active ? raw : in;
        for (int i = 0; i < kEngineCount; ++i) {
            if (!eng[i].active) continue;
            const float roughDelta = eng[i].envFlutterDb - base.envFlutterDb;
            if (roughDelta >= kRoughnessDeltaDb) {
                std::snprintf(line, sizeof(line),
                    "  - El SISTEMA %d (%s) suena RONCO: agrega aspereza/ruido musical (+%.2f dB de modulacion sobre la entrada). Tipico de denoiser espectral; probar bajar intensidad (mezclar mas señal seca) o cambiar de motor.\n",
                    i + 1, engineName(i), roughDelta);
                r.append(line);
                any = true;
            }
            const float tiltDelta = eng[i].lowBandRatio - base.lowBandRatio;
            if (tiltDelta >= kTiltDelta) {
                std::snprintf(line, sizeof(line),
                    "  - El SISTEMA %d (%s) apaga los agudos (timbre mas grave/ronco): +%.0f%% de energia en graves vs la entrada.\n",
                    i + 1, engineName(i), tiltDelta * 100.0f);
                r.append(line);
                any = true;
            }
        }

        // Etapa posterior (pipeline) agrega matraca.
        if (active >= 0 && active < kEngineCount && eng[active].active) {
            const double post = out.clicksPerSec - eng[active].clicksPerSec;
            if (post >= kIntroRate) {
                std::snprintf(line, sizeof(line),
                    "  - Una etapa POSTERIOR al sistema (WDRC/EQ/MPO/volumen) agrega matraca (+%.2f clicks/s sobre la salida del sistema).\n",
                    post);
                r.append(line);
                any = true;
            }
        }
        if (out.clipCount > 0) {
            append(r, "  - Hay CLIPPING en la salida final: revisar volumen/MPO (los picos recortados suenan como matraca).\n");
            any = true;
        }

        if (!any) {
            append(r, "  - Sin matraca significativa detectada en esta sesion. La calidad se mantiene alta en todas las etapas.\n");
        }
    }

    /// Tasa (clicks/s) a partir de la cual se considera audible/notable.
    static constexpr double kNoticeableRate = 0.5;
    /// Delta de tasa (clicks/s) para atribuir "introduce matraca".
    static constexpr double kIntroRate = 0.5;
    /// Delta de modulación (dB) para atribuir "aspereza/ronco" a un sistema.
    static constexpr float kRoughnessDeltaDb = 1.5f;
    /// Delta de ratio de graves para atribuir "apaga agudos / timbre ronco".
    static constexpr float kTiltDelta = 0.12f;

    int sampleRate_ = 48000;
    ArtifactMonitor rawMic_;
    ArtifactMonitor input_;
    ArtifactMonitor engines_[kEngineCount];
    ArtifactMonitor output_;
    std::atomic<int> activeEngineIdx_{-1};
};

#endif  // HEARING_AID_DENOISER_ARTIFACT_LOG_H
