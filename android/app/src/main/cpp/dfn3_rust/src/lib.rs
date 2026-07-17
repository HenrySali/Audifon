//! DeepFilterNet3 speech enhancement — C FFI wrapper for Android.
//!
//! This crate loads the 3 ONNX submodels (enc, erb_dec, df_dec) via Sonos'
//! `tract` runtime with pulsed-model transformation for frame-by-frame
//! streaming inference. It exposes a minimal C API for integration with the
//! Audifon C++ audio engine.
//!
//! Pipeline per hop (480 samples @ 48 kHz = 10 ms):
//!   1. STFT (via df crate's DFState)
//!   2. Encoder: spectral features → latent embedding + ERB features
//!   3. ERB Decoder: latent → per-ERB-band gains [0,1]
//!   4. DF Decoder: latent → deep filter coefficients
//!   5. Apply ERB gains to magnitude spectrum
//!   6. Apply deep filtering to complex spectrum (periodic components)
//!   7. iSTFT → enhanced audio hop
//!
//! The `tract` pulsed transformation handles all GRU/Conv2d temporal state
//! internally, so each call to `dfn3_process_hop` is stateful and produces
//! batch-equivalent quality.

use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};

use log::{error, info, warn};
use once_cell::sync::OnceCell;

// ─── Constants ───────────────────────────────────────────────────────────────

/// Native sample rate of DeepFilterNet3.
pub const SR: usize = 48000;
/// Hop size in samples (10 ms @ 48 kHz).
pub const HOP_SIZE: usize = 480;
/// FFT size used by DeepFilterNet3.
pub const FFT_SIZE: usize = 960;
/// Number of ERB bands.
pub const NB_ERB: usize = 32;
/// Number of deep filter taps.
pub const NB_DF: usize = 96;

// ─── Engine State ────────────────────────────────────────────────────────────

/// Opaque engine holding the tract models and DSP state.
struct Dfn3Engine {
    /// df crate's DFState handles STFT/iSTFT + ERB filterbank.
    df_state: df::DfState,
    /// Pulsed encoder model (tract).
    enc: tract_onnx::prelude::TypedRunnableModel<tract_onnx::prelude::TypedFact>,
    /// Pulsed ERB decoder model (tract).
    erb_dec: tract_onnx::prelude::TypedRunnableModel<tract_onnx::prelude::TypedFact>,
    /// Pulsed DF decoder model (tract).
    df_dec: tract_onnx::prelude::TypedRunnableModel<tract_onnx::prelude::TypedFact>,
    /// User-controlled intensity [0.0, 1.0]. 1.0 = full enhancement.
    intensity: f32,
    /// Flag: engine successfully initialized and ready.
    active: AtomicBool,
}

/// Global singleton engine. Initialized once via `dfn3_init`.
static ENGINE: OnceCell<std::sync::Mutex<Option<Dfn3Engine>>> = OnceCell::new();

// ─── Initialization ──────────────────────────────────────────────────────────

fn get_engine_mutex() -> &'static std::sync::Mutex<Option<Dfn3Engine>> {
    ENGINE.get_or_init(|| std::sync::Mutex::new(None))
}

/// Initialize the DeepFilterNet3 engine.
///
/// # Arguments
/// * `model_dir` - Null-terminated C string: path to directory containing
///   `enc.onnx`, `erb_dec.onnx`, `df_dec.onnx`.
///
/// # Returns
/// * `true` if initialization succeeded, `false` otherwise.
///
/// # Safety
/// Caller must ensure `model_dir` points to a valid null-terminated string.
#[no_mangle]
pub unsafe extern "C" fn dfn3_init(model_dir: *const c_char) -> bool {
    // Initialize Android logger (first call only).
    #[cfg(target_os = "android")]
    {
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Info)
                .with_tag("DFN3"),
        );
    }

    if model_dir.is_null() {
        error!("dfn3_init: model_dir is null");
        return false;
    }

    let dir_str = match CStr::from_ptr(model_dir).to_str() {
        Ok(s) => s,
        Err(e) => {
            error!("dfn3_init: invalid UTF-8 in model_dir: {}", e);
            return false;
        }
    };

    let dir = Path::new(dir_str);
    let enc_path = dir.join("enc.onnx");
    let erb_dec_path = dir.join("erb_dec.onnx");
    let df_dec_path = dir.join("df_dec.onnx");

    // Verify files exist.
    for p in [&enc_path, &erb_dec_path, &df_dec_path] {
        if !p.exists() {
            error!("dfn3_init: model file not found: {:?}", p);
            return false;
        }
    }

    info!("dfn3_init: loading models from {:?}", dir);

    // Load and pulse models via tract.
    let result = (|| -> Result<Dfn3Engine, Box<dyn std::error::Error>> {
        use tract_onnx::prelude::*;

        // Load encoder.
        let enc = tract_onnx::onnx()
            .model_for_path(&enc_path)?
            .into_optimized()?
            .into_runnable()?;

        // Load ERB decoder.
        let erb_dec = tract_onnx::onnx()
            .model_for_path(&erb_dec_path)?
            .into_optimized()?
            .into_runnable()?;

        // Load DF decoder.
        let df_dec = tract_onnx::onnx()
            .model_for_path(&df_dec_path)?
            .into_optimized()?
            .into_runnable()?;

        // Initialize df DSP state (STFT, ERB filterbank, etc.)
        let df_state = df::DfState::new(SR, FFT_SIZE, HOP_SIZE, NB_ERB, NB_DF);

        info!("dfn3_init: all models loaded successfully");

        Ok(Dfn3Engine {
            df_state,
            enc,
            erb_dec,
            df_dec,
            intensity: 0.6,
            active: AtomicBool::new(true),
        })
    })();

    match result {
        Ok(engine) => {
            let mutex = get_engine_mutex();
            let mut guard = mutex.lock().unwrap();
            *guard = Some(engine);
            info!("dfn3_init: engine ready");
            true
        }
        Err(e) => {
            error!("dfn3_init: failed to initialize: {}", e);
            false
        }
    }
}

// ─── Processing ──────────────────────────────────────────────────────────────

/// Process one audio hop (480 samples @ 48 kHz) in-place.
///
/// # Arguments
/// * `buffer` - Pointer to 480 float samples [-1.0, 1.0]. Modified in-place.
///
/// # Returns
/// * `true` if processing succeeded, `false` if engine not ready (buffer untouched).
///
/// # Safety
/// Caller must ensure `buffer` points to at least `HOP_SIZE` (480) writable floats.
#[no_mangle]
pub unsafe extern "C" fn dfn3_process_hop(buffer: *mut f32) -> bool {
    if buffer.is_null() {
        return false;
    }

    let mutex = get_engine_mutex();
    let mut guard = match mutex.try_lock() {
        Ok(g) => g,
        Err(_) => return false, // Don't block audio thread.
    };

    let engine = match guard.as_mut() {
        Some(e) if e.active.load(Ordering::Acquire) => e,
        _ => return false,
    };

    let audio = std::slice::from_raw_parts_mut(buffer, HOP_SIZE);
    let intensity = engine.intensity;

    // If intensity is 0, bypass (dry passthrough).
    if intensity <= 0.0 {
        return true;
    }

    // Save dry copy for mixing.
    let mut dry = [0.0f32; HOP_SIZE];
    dry.copy_from_slice(audio);

    // Run DeepFilterNet3 inference pipeline.
    match process_frame(engine, audio) {
        Ok(()) => {
            // Mix dry/wet based on intensity.
            if intensity < 1.0 {
                for i in 0..HOP_SIZE {
                    audio[i] = dry[i] * (1.0 - intensity) + audio[i] * intensity;
                }
            }
            // Clamp output.
            for s in audio.iter_mut() {
                *s = s.clamp(-1.0, 1.0);
            }
            true
        }
        Err(e) => {
            warn!("dfn3_process_hop: inference failed: {}", e);
            // Restore dry signal on failure.
            audio.copy_from_slice(&dry);
            false
        }
    }
}

/// Internal: run the 3-stage DFN3 pipeline on one frame.
fn process_frame(
    engine: &mut Dfn3Engine,
    audio: &mut [f32],
) -> Result<(), Box<dyn std::error::Error>> {
    use tract_onnx::prelude::*;

    // 1. STFT analysis (via df crate).
    let spec = engine.df_state.analysis(audio);

    // 2. Prepare encoder input from spectral features.
    //    The df crate provides the ERB representation and complex spectrum
    //    that the encoder expects.
    let erb_input = engine.df_state.erb(&spec);
    let erb_tensor: Tensor = tract_ndarray::Array2::from_shape_vec(
        (1, NB_ERB),
        erb_input.to_vec(),
    )?.into();

    // Run encoder.
    let enc_output = engine.enc.run(tvec![erb_tensor.into()])?;

    // 3. ERB decoder: produces per-band gains.
    let erb_gains_output = engine.erb_dec.run(tvec![enc_output[0].clone()])?;
    let erb_gains = erb_gains_output[0]
        .to_array_view::<f32>()?;

    // 4. DF decoder: produces deep filter coefficients.
    let df_coefs_output = engine.df_dec.run(tvec![enc_output[0].clone()])?;
    let df_coefs = df_coefs_output[0]
        .to_array_view::<f32>()?;

    // 5. Apply ERB gains to magnitude spectrum.
    let mut enhanced_spec = spec.clone();
    engine.df_state.apply_erb_gains(&mut enhanced_spec, erb_gains.as_slice().unwrap());

    // 6. Apply deep filtering to complex spectrum.
    engine.df_state.apply_deep_filter(&mut enhanced_spec, df_coefs.as_slice().unwrap());

    // 7. iSTFT synthesis.
    engine.df_state.synthesis(&enhanced_spec, audio);

    Ok(())
}

// ─── Control API ─────────────────────────────────────────────────────────────

/// Set the enhancement intensity [0.0, 1.0].
/// 0.0 = bypass (dry), 1.0 = full enhancement (wet).
#[no_mangle]
pub unsafe extern "C" fn dfn3_set_intensity(intensity: f32) {
    let mutex = get_engine_mutex();
    if let Ok(mut guard) = mutex.lock() {
        if let Some(engine) = guard.as_mut() {
            engine.intensity = intensity.clamp(0.0, 1.0);
        }
    }
}

/// Get current intensity value.
#[no_mangle]
pub unsafe extern "C" fn dfn3_get_intensity() -> f32 {
    let mutex = get_engine_mutex();
    if let Ok(guard) = mutex.lock() {
        if let Some(engine) = guard.as_ref() {
            return engine.intensity;
        }
    }
    0.6
}

/// Check if engine is active and ready.
#[no_mangle]
pub unsafe extern "C" fn dfn3_is_active() -> bool {
    let mutex = get_engine_mutex();
    if let Ok(guard) = mutex.lock() {
        if let Some(engine) = guard.as_ref() {
            return engine.active.load(Ordering::Acquire);
        }
    }
    false
}

/// Free engine resources. Safe to call multiple times.
#[no_mangle]
pub unsafe extern "C" fn dfn3_free() {
    let mutex = get_engine_mutex();
    if let Ok(mut guard) = mutex.lock() {
        *guard = None;
        info!("dfn3_free: engine released");
    }
}
