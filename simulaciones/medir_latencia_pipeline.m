%% medir_latencia_pipeline.m — Medición de latencia del pipeline DPDFNet
%% =========================================================================
%% Genera una señal de prueba (impulso + chirp), la pasa por un modelo
%% simplificado del pipeline DSP (resample 48→16, acumulación, hop, STFT,
%% upsample 16→48) y mide el retardo algorítmico total en ms.
%%
%% Uso:
%%   octave --no-gui medir_latencia_pipeline.m
%%
%% Resultado esperado:
%%   - Latencia algorítmica mínima del DPDFNet (Ultra o Turbo = idéntica)
%%   - Desglose por etapa: downsampler, accumulator, STFT, OLA, upsampler
%%   - Gráfico de correlación cruzada para medir el delay real
%%
%% Autor: bioingeniero (PSK Hearing Aid project)
%% Fecha: 2025

clear; close all; clc;

%% ─── Parámetros del pipeline (idénticos Ultra y Turbo) ───────────────────
SR_NATIVE   = 48000;   % Hz — sample rate del callback Oboe
SR_MODEL    = 16000;   % Hz — sample rate interno del DPDFNet-4
HOP_SIZE    = 160;     % samples @ 16 kHz (10 ms)
WIN_SIZE    = 320;     % samples @ 16 kHz (20 ms) — Vorbis window
FFT_SIZE    = 320;     % DFT directo (sherpa-onnx pipeline)
BUFFER_SIZE = 256;     % frames por callback Oboe (typical)

% Ratio de resampleo
RATIO_DOWN = SR_NATIVE / SR_MODEL;  % 3 (48k → 16k)
RATIO_UP   = SR_NATIVE / SR_MODEL;  % 3 (16k → 48k)

%% ─── Cálculo teórico de latencia algorítmica ────────────────────────────
fprintf('\n=== ANÁLISIS DE LATENCIA DEL PIPELINE DPDFNet-4 ===\n\n');

% 1. Callback buffer (I/O latency — Oboe framesPerBurst)
t_buffer_ms = BUFFER_SIZE / SR_NATIVE * 1000;
fprintf('1. Callback buffer (framesPerBurst):     %d samples = %.2f ms\n', ...
        BUFFER_SIZE, t_buffer_ms);

% 2. Downsampler (polyphase sinc, ~6 zeros, group delay)
%    LinearResample con num_zeros=6, cutoff=0.99*8000
%    Group delay del sinc filter ≈ num_zeros / (2 * cutoff) ≈ 6/(2*0.99*8000/48000)
%    En samples @48k ≈ 18; en ms ≈ 0.375 ms
resamp_zeros = 6;
resamp_delay_48k = resamp_zeros;  % samples @ 48k (approx group delay)
t_downsamp_ms = resamp_delay_48k / SR_NATIVE * 1000;
fprintf('2. Downsampler (sinc, %d zeros):           ~%d samples@48k = %.3f ms\n', ...
        resamp_zeros, resamp_delay_48k, t_downsamp_ms);

% 3. Acumulador + hop processing
%    Necesita HOP_SIZE samples @16k para procesar. En el peor caso, llegan
%    BUFFER_SIZE/3 ≈ 85 samples @16k por callback → necesita 2 callbacks
%    para juntar 1 hop de 160.
samples_per_cb_16k = floor(BUFFER_SIZE / RATIO_DOWN);
cbs_per_hop = ceil(HOP_SIZE / samples_per_cb_16k);
t_accum_ms = (cbs_per_hop - 1) * t_buffer_ms;  % espera extra
fprintf('3. Acumulador (espera para 1 hop):         %d cb × %.2f ms = %.2f ms\n', ...
        cbs_per_hop-1, t_buffer_ms, t_accum_ms);
fprintf('   (Cada callback da ~%d samples@16k, hop necesita %d)\n', ...
        samples_per_cb_16k, HOP_SIZE);

% 4. STFT window look-ahead (50% overlap → 1 hop de latencia)
%    Sherpa-onnx descarta el PRIMER frame de output (started=false en processHop).
%    Eso agrega exactamente 1 hop = 10 ms de priming latency.
t_stft_latency_ms = HOP_SIZE / SR_MODEL * 1000;
fprintf('4. STFT priming (1er frame descartado):    %d samples@16k = %.2f ms\n', ...
        HOP_SIZE, t_stft_latency_ms);

% 5. OLA synthesis — no agrega latencia extra (same hop alignment)
t_ola_ms = 0;
fprintf('5. OLA synthesis:                          0 ms (alineado al hop)\n');

% 6. Upsampler (polyphase sinc, symmetric group delay)
t_upsamp_ms = resamp_delay_48k / SR_NATIVE * 1000;
fprintf('6. Upsampler (sinc, %d zeros):             ~%d samples@48k = %.3f ms\n', ...
        resamp_zeros, resamp_delay_48k, t_upsamp_ms);

% 7. Wet ring delay (FIFO entre upsampler y mix en el callback)
%    El wet ring se lee en el SIGUIENTE callback, así que agrega ~1 buffer.
t_wetring_ms = t_buffer_ms;
fprintf('7. Wet ring (FIFO→next callback):          %d frames = %.2f ms\n', ...
        BUFFER_SIZE, t_wetring_ms);

% 8. Crossfade enable/disable (800 samples @48k = 16.7 ms, pero no es latencia)
t_xfade_ms = 800 / SR_NATIVE * 1000;
fprintf('8. Crossfade (transición on/off):          %d samples = %.2f ms [NO latencia]\n', ...
        800, t_xfade_ms);

% ─── TOTAL ALGORÍTMICO ──────────────────────────────────────────────────
t_total_algo_ms = t_buffer_ms + t_downsamp_ms + t_accum_ms + ...
                  t_stft_latency_ms + t_ola_ms + t_upsamp_ms + t_wetring_ms;
fprintf('\n─── LATENCIA ALGORÍTMICA TOTAL (DPDFNet): %.2f ms ───\n', t_total_algo_ms);
fprintf('    (idéntica para Ultra FP32 y Turbo INT8 — misma estructura)\n\n');

% ─── Latencia de inferencia (lo ÚNICO que cambia con INT8) ───────────────
fprintf('=== DIFERENCIA TURBO vs ULTRA ===\n\n');
t_inference_fp32_ms = 3.0;  % típico en Snapdragon 6xx/7xx
t_inference_int8_ms = 1.5;  % típico INT8 con NNAPI/XNNPACK
fprintf('Inferencia FP32 (Ultra):    ~%.1f ms por hop\n', t_inference_fp32_ms);
fprintf('Inferencia INT8 (Turbo):    ~%.1f ms por hop\n', t_inference_int8_ms);
fprintf('Ahorro por hop:             ~%.1f ms (DENTRO del budget del callback)\n', ...
        t_inference_fp32_ms - t_inference_int8_ms);
fprintf('Impacto en LATENCIA END-TO-END: CERO — la inferencia corre DENTRO\n');
fprintf('del callback de 5.33ms. Si termina antes, el resultado espera en el\n');
fprintf('wet ring hasta el próximo callback. No hay shortcut posible.\n\n');

%% ─── Simulación numérica: medir delay con cross-correlación ─────────────
fprintf('=== SIMULACIÓN NUMÉRICA (bypass — delay puro del pipeline) ===\n\n');

% Señal de prueba: impulso en t=100ms seguido de chirp 200-4000 Hz
dur_s = 0.5;
N = round(dur_s * SR_NATIVE);
t = (0:N-1)' / SR_NATIVE;

% Impulso limpio en sample 4800 (100ms)
impulse_pos = round(0.1 * SR_NATIVE);  % sample 4800
x = zeros(N, 1);
x(impulse_pos) = 1.0;

% Agregar chirp para tener energía sostenida (cross-corr más robusta)
chirp_start = round(0.15 * SR_NATIVE);
chirp_end = round(0.35 * SR_NATIVE);
f0 = 200; f1 = 4000;
chirp_t = (0:(chirp_end-chirp_start))' / SR_NATIVE;
chirp_sig = 0.3 * sin(2*pi * (f0 + (f1-f0)/(2*(chirp_end-chirp_start)/SR_NATIVE) .* chirp_t) .* chirp_t);
x(chirp_start:chirp_end) = x(chirp_start:chirp_end) + chirp_sig;

% ─── Pipeline simulado (modelo = bypass, sin inferencia ONNX) ────────────
% Esto mide SOLO el retardo estructural (resample + buffer + OLA)

% Paso 1: Downsample 48→16 (decimate by 3 con filtro anti-alias)
[p_down, q_down] = rat(SR_MODEL / SR_NATIVE);  % 1/3
x_16k = resample(x, p_down, q_down);

% Paso 2: Procesar en hops de 160 con OLA (50% overlap, Vorbis window)
%   Simulamos: shift buffer, window, "modelo bypass", window, OLA
%   El primer hop se descarta (priming)
n16 = length(x_16k);
n_hops = floor(n16 / HOP_SIZE);

% Vorbis window
vorbis_win = zeros(WIN_SIZE, 1);
for i = 1:WIN_SIZE
    s = sin(pi/2 * (i-0.5) / (WIN_SIZE/2));
    vorbis_win(i) = sin(pi/2 * s^2);
end

% STFT + iSTFT con bypass (modelo = identidad en espectro)
analysis_buf = zeros(WIN_SIZE, 1);
ola_buf = zeros(WIN_SIZE, 1);
y_16k = zeros(n16, 1);
out_pos = 0;
started = false;

for h = 1:n_hops
    hop_start = (h-1) * HOP_SIZE + 1;
    hop_end = hop_start + HOP_SIZE - 1;
    if hop_end > n16, break; end
    
    hop_data = x_16k(hop_start:hop_end);
    
    % Shift analysis buffer
    analysis_buf(1:HOP_SIZE) = analysis_buf(HOP_SIZE+1:WIN_SIZE);
    analysis_buf(HOP_SIZE+1:WIN_SIZE) = hop_data;
    
    % Apply analysis window
    frm = analysis_buf .* vorbis_win;
    
    % FFT → "model bypass" → iFFT  (identidad perfecta)
    spec = fft(frm, FFT_SIZE);
    synth = real(ifft(spec, FFT_SIZE));
    synth = synth(1:WIN_SIZE);
    
    % Apply synthesis window
    synth = synth .* vorbis_win;
    
    % OLA: shift left by hop, add
    ola_buf(1:HOP_SIZE) = ola_buf(HOP_SIZE+1:WIN_SIZE);
    ola_buf(HOP_SIZE+1:WIN_SIZE) = 0;
    ola_buf = ola_buf + synth;
    
    % Extract output (skip first frame = priming)
    if ~started
        started = true;
        continue;
    end
    
    % Output hop
    if out_pos + HOP_SIZE <= n16
        y_16k(out_pos+1 : out_pos+HOP_SIZE) = ola_buf(1:HOP_SIZE);
    end
    out_pos = out_pos + HOP_SIZE;
end
y_16k = y_16k(1:out_pos);

% Paso 3: Upsample 16→48
[p_up, q_up] = rat(SR_NATIVE / SR_MODEL);  % 3/1
y_48k = resample(y_16k, p_up, q_up);

% ─── Medir delay con cross-correlación ───────────────────────────────────
% Recortar al mínimo largo
min_len = min(length(x), length(y_48k));
x_trim = x(1:min_len);
y_trim = y_48k(1:min_len);

% Cross-correlación normalizada
[corr_val, lags] = xcorr(y_trim, x_trim, SR_NATIVE * 0.1);  % ±100ms
[~, max_idx] = max(abs(corr_val));
delay_samples = lags(max_idx);
delay_ms = delay_samples / SR_NATIVE * 1000;

fprintf('Delay medido (cross-correlación):     %d samples = %.2f ms\n', ...
        delay_samples, delay_ms);
fprintf('Delay teórico (calculado arriba):     %.2f ms\n', t_total_algo_ms);
fprintf('Discrepancia:                         %.2f ms\n\n', ...
        abs(delay_ms - t_total_algo_ms));

%% ─── Comparación con RNNoise ─────────────────────────────────────────────
fprintf('=== COMPARACIÓN DE LATENCIA POR MOTOR ===\n\n');
rnnoise_hop = 480;  % 10 ms @ 48 kHz (RNNoise opera a 48k nativo)
rnnoise_latency_ms = rnnoise_hop / SR_NATIVE * 1000;
fprintf('Motor         | Hop     | SR interno | Resample | Latencia algo.\n');
fprintf('─────────────────────────────────────────────────────────────────\n');
fprintf('RNNoise       | 480@48k | 48 kHz     | NO       | ~%.1f ms\n', ...
        rnnoise_latency_ms + t_buffer_ms);
fprintf('DPDFNet Ultra | 160@16k | 16 kHz     | SI (×3)  | ~%.1f ms\n', t_total_algo_ms);
fprintf('DPDFNet Turbo | 160@16k | 16 kHz     | SI (×3)  | ~%.1f ms\n', t_total_algo_ms);
fprintf('─────────────────────────────────────────────────────────────────\n');
fprintf('CONCLUSIÓN: Turbo INT8 ≠ menor latencia. Latencia = Ultra.\n');
fprintf('            RNNoise tiene la menor latencia algorítmica.\n\n');

%% ─── Gráfico ─────────────────────────────────────────────────────────────
figure('Position', [100 100 900 600]);

subplot(3,1,1);
plot((1:min_len)/SR_NATIVE*1000, x_trim, 'b');
title('Señal de entrada (impulso + chirp @ 48 kHz)');
xlabel('Tiempo [ms]'); ylabel('Amplitud');
xlim([80 250]);

subplot(3,1,2);
plot((1:min_len)/SR_NATIVE*1000, y_trim, 'r');
title(sprintf('Señal de salida (post-pipeline bypass, delay = %.1f ms)', delay_ms));
xlabel('Tiempo [ms]'); ylabel('Amplitud');
xlim([80 250]);

subplot(3,1,3);
plot(lags/SR_NATIVE*1000, abs(corr_val)/max(abs(corr_val)), 'k');
hold on;
xline(delay_ms, 'r--', sprintf('%.1f ms', delay_ms), 'LineWidth', 1.5);
title('Cross-correlación normalizada (pico = delay)');
xlabel('Lag [ms]'); ylabel('|Correlación|');
xlim([-50 100]);

sgtitle('Medición de latencia del pipeline DPDFNet-4 (Ultra = Turbo)', ...
        'FontWeight', 'bold');

% Guardar figura
print('-dpng', '-r150', 'latencia_pipeline_dpdfnet.png');
fprintf('Gráfico guardado: latencia_pipeline_dpdfnet.png\n');

%% ─── Diagnóstico: qué PODRÍA reducir la latencia ────────────────────────
fprintf('\n=== RECOMENDACIONES PARA REDUCIR LATENCIA REAL ===\n\n');
fprintf('1. REDUCIR BUFFER SIZE (Oboe framesPerBurst): 256→128→64 frames\n');
fprintf('   De %.1f ms a %.1f ms a %.1f ms (impacto directo)\n', ...
        256/SR_NATIVE*1000, 128/SR_NATIVE*1000, 64/SR_NATIVE*1000);
fprintf('2. Usar RNNoise en vez de DPDFNet (opera @48k, sin resample)\n');
fprintf('   Ahorra el overhead de resample + acumulación: ~%.1f ms\n', ...
        t_accum_ms + t_downsamp_ms + t_upsamp_ms);
fprintf('3. Reducir hop del DPDFNet (requiere re-entrenar el modelo)\n');
fprintf('   hop=80 @16k → 5ms de priming vs 10ms actual\n');
fprintf('4. NNAPI delegate para INT8 (no reduce latencia pero sí CPU)\n');
fprintf('   Libera budget del callback para procesar bloques más chicos\n');
fprintf('5. Async inference (procesar hop N mientras se reproduce hop N-1)\n');
fprintf('   Requiere ring buffer de 2 hops → +10ms extra, contradictorio\n');
fprintf('\n');
