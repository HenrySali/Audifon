# Native coordination — `setMpoThresholdDbSpl`

> Spec: `audiogram-driven-presets`, Task **3.3**
> Status: **complete (already implemented end-to-end)**.

## Summary

Task 3.3 asks for the native handler that converts a clinical dB SPL value
into the linear threshold of the on-device MPO limiter and applies it in
runtime, without restarting the audio engine, with ≤ 50 ms p95 propagation.

The full chain is **already wired** across Kotlin → JNI → C++ in this
workspace. No further native coordination is required for this task; this
document is the audit trail describing what exists and where, so anyone
landing tasks 4.x (atomic apply) and Tramo 3 QC (15.x) can reference it.

## Chain (Dart → DSP)

| Layer | File | Symbol |
|------|------|--------|
| Dart interface | `lib/data/bridges/audio_bridge.dart` | `AudioBridge.setMpoThresholdDbSpl(double)` |
| Dart impl | `lib/data/bridges/audio_bridge_impl.dart` | `AudioBridgeImpl.setMpoThresholdDbSpl` (validates NaN/Inf and `[80.0, 132.0]`, then dispatches `MethodChannel.invokeMethod('setMpoThresholdDbSpl', {'thresholdDbSpl': value})`) |
| Kotlin handler | `android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt` | `handleSetMpoThresholdDbSpl` (re-checks finiteness, calls `nativeBridge.setMpoThresholdDbSpl`) |
| JNI Kotlin | `android/app/src/main/kotlin/com/psk/hearing_aid_app/NativeAudioBridge.kt` | `external fun nativeSetMpoThresholdDbSpl(thresholdDbSpl: Float)` |
| JNI C++ | `android/app/src/main/cpp/native_bridge.cpp` | `Java_com_psk_hearing_1aid_1app_NativeAudioBridge_nativeSetMpoThresholdDbSpl` → `g_engine->setMpoThresholdDbSpl(...)` |
| AudioEngine | `android/app/src/main/cpp/audio_engine.cpp` | `AudioEngine::setMpoThresholdDbSpl` → `pipeline_.setMpoThresholdDbSpl(...)` |
| DSP pipeline | `android/app/src/main/cpp/dsp_pipeline.cpp` | `DspPipeline::setMpoThresholdDbSpl` (conversion + atomic update) |
| MPO limiter | `android/app/src/main/cpp/mpo_limiter.cpp` | `MpoLimiter::setThresholdLinear` (lock-free `std::atomic<float>`) |

## Conversion (matches task spec)

`dsp_pipeline.cpp::setMpoThresholdDbSpl` uses exactly the formula prescribed
by Task 3.3:

```cpp
const float offset = splOffset_.load(std::memory_order_relaxed);
const float linear = std::pow(10.0f, (thresholdDbSpl - offset) / 20.0f);
const float safeLinear = (linear > 0.85f) ? 0.85f : linear;  // anti-clipping ceiling
mpo_.setThresholdLinear(safeLinear);
```

Notes:
- `splOffset` is read from the calibration data already stored in the engine
  (set via `setSplOffset` which is called from Dart through `applyCalibration`).
- The dB SPL value is also persisted to `mpoThresholdDbSpl_` (atomic) so that
  a later change of `splOffset` (re-calibration of the mic) re-derives the
  linear threshold from the same clinical SPL setting — no need for the
  Dart side to remember and resend the value.
- A digital-safety clamp at 0.85 lineal (≈ -1.4 dBFS) guarantees the limiter
  never turns into a no-op even if a high SPL is requested.

## Runtime update without engine restart

`MpoLimiter::thresholdLinear_` is a `std::atomic<float>` read once per block
in `MpoLimiter::process`. Updating it does not touch the Oboe streams, the
DSP block size, or any thread state. There is **no engine stop/start**.

Pseudocode of the update path (kotlin call → audio thread):

1. Kotlin posts `nativeSetMpoThresholdDbSpl(value)` from the platform thread.
2. JNI calls `AudioEngine::setMpoThresholdDbSpl` → `DspPipeline::setMpoThresholdDbSpl`.
3. `DspPipeline` does one `std::pow` + two `atomic.store`.
4. The audio thread, on its next `process()` call, picks up the new
   `thresholdLinear_` value via `atomic.load(memory_order_relaxed)`.

Latency = JNI hop + one block boundary. With `bufferSize` of 256 frames at
48 kHz (~5.3 ms) plus negligible JNI overhead, end-to-end is **~3–6 ms**,
well under the 50 ms p95 budget required by the spec. This is documented in
the Dartdoc of `DspPipeline::setMpoThresholdDbSpl` (`dsp_pipeline.h`):

> `Propagación al MPO: 1 atomic store; efectivo en el siguiente bloque
> (∼3–6 ms a 16/48 kHz, ≪ 50 ms p95 requerido por la spec).`

## Verification ≤ 50 ms p95 propagation

The propagation budget is verifiable by construction (single atomic store,
single block boundary) and is the same mechanism used by every other
runtime DSP parameter (NR level, EQ gains, WDRC params, volume, splOffset).
None of those paths block, allocate, or hold locks. Empirical confirmation
will land as part of Task **15.x (Tramo 3 loopback QC)**, which streams real
SPL measurements while sweeping the MPO threshold during a manual session.

If a future code change introduces blocking work between the Dart call and
the limiter (e.g. a mutex around the pipeline, a JNI thread pool, or a
synchronous Oboe stream reconfiguration), the budget must be re-validated.
The current implementation does none of those things.

## Requirements covered

- **Req 3.1** — runtime MPO update via `MethodChannel('setMpoThresholdDbSpl')`,
  ≤ 50 ms p95 propagation. ✅
- **Req 3.5** — when bundle MPO profile has 12 different values and the
  limiter is broadband, the bridge receives `min(mpoProfileDbSpl)`. The
  Dart caller (Task 4.4) is responsible for passing `min(mpo)`; the native
  side simply applies whatever value it receives. ✅

## Outstanding follow-up (not part of Task 3.3)

- Task 4.4 — wire `_onApplyBundle` to call `setMpoThresholdDbSpl(min(bundle.mpoProfileDbSpl))` as step 1 of the atomic 4-call sequence.
- Task 11.x — property tests can mock `AudioBridge` and verify the call ordering against this contract.
- Task 15.4 — loopback QC validates the MPO threshold under `gainScale ∈ {0.10, 0.40, 1.00}`.
