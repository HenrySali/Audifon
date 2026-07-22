//! DeepFilterNet3 speech enhancement — C FFI wrapper for Android.
//!
//! Uses the `df` crate for DSP (STFT/iSTFT, ERB features, gain application)
//! and `tract-onnx` for model inference (enc, erb_dec, df_dec).
//!
//! Pipeline per hop (480 samples @ 48 kHz = 10 ms):
//!   1. STFT analysis via DFState::analysis
//!   2. Extract ERB features via DFState::feat_erb
//!   3. Encoder inference (tract)
//!   4. ERB decoder (tract) → per-band gains
//!   5. DF decoder (tract) → deep filter coefficients (unused for now, simplified)
//!   6. Apply ERB gains via DFState::apply_mask
//!   7. iSTFT synthesis via DFState::synthesis

use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use log::{error, info, warn};
use num_complex::Complex32;
use once_cell::sync::OnceCell;

use df::DFState;

use tract_onnx::prelude::*;

// ─── Constants ───────────────────────────────────────────────────────────────

pub const SR: usize = 48000;
pub const HOP_SIZE: usize = 480;
pub const FFT_SIZE: usize = 960;
pub const NB_ERB: usize = 32;
pub const NB_DF: usize = 96;
/// Number of complex frequency bins = FFT_SIZE / 2 + 1
pub const NB_FREQS: usize = FFT_SIZE / 2 + 1;

// ─── Engine State ────────────────────────────────────────────────────────────

type TractModel = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

struct Dfn3Engine {
    df_state: DFState,
    enc: TractModel,
    erb_dec: TractModel,
    df_dec: TractModel,
    /// Spectral buffer for STFT output (NB_FREQS complex bins + 1 padding to
    /// prevent off-by-one OOB in deep_filter crate's internal iteration)
    spec_buf: Vec<Complex32>,
    /// ERB feature buffer
    erb_buf: Vec<f32>,
    /// User-controlled intensity [0.0, 1.0]
    intensity: f32,
    active: AtomicBool,
}

unsafe impl Send for Dfn3Engine {}

static ENGINE: OnceCell<std::sync::Mutex<Option<Dfn3Engine>>> = OnceCell::new();

fn get_engine_mutex() -> &'static std::sync::Mutex<Option<Dfn3Engine>> {
    ENGINE.get_or_init(|| std::sync::Mutex::new(None))
}

// ─── Initialization ──────────────────────────────────────────────────────────

/// Initialize the DeepFilterNet3 engine.
///
/// # Safety
/// `model_dir` must point to a valid null-terminated C string (directory path
/// containing enc.onnx, erb_dec.onnx, df_dec.onnx).
#[no_mangle]
pub unsafe extern "C" fn dfn3_init(model_dir: *const c_char) -> bool {
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
            error!("dfn3_init: invalid UTF-8: {}", e);
            return false;
        }
    };

    let dir = Path::new(dir_str);
    let enc_path = dir.join("enc.onnx");
    let erb_dec_path = dir.join("erb_dec.onnx");
    let df_dec_path = dir.join("df_dec.onnx");

    for p in [&enc_path, &erb_dec_path, &df_dec_path] {
        if !p.exists() {
            error!("dfn3_init: file not found: {:?}", p);
            return false;
        }
    }

    info!("dfn3_init: loading models from {:?}", dir);

    let result = (|| -> Result<Dfn3Engine, Box<dyn std::error::Error>> {
        let enc = tract_onnx::onnx()
            .model_for_path(&enc_path)?
            .into_optimized()?
            .into_runnable()?;

        let erb_dec = tract_onnx::onnx()
            .model_for_path(&erb_dec_path)?
            .into_optimized()?
            .into_runnable()?;

        let df_dec = tract_onnx::onnx()
            .model_for_path(&df_dec_path)?
            .into_optimized()?
            .into_runnable()?;

        let df_state = DFState::new(SR, FFT_SIZE, HOP_SIZE, NB_ERB, NB_DF);

        info!("dfn3_init: all models loaded");

        Ok(Dfn3Engine {
            df_state,
            enc,
            erb_dec,
            df_dec,
            // Allocate NB_FREQS + 1 to prevent off-by-one panic in df crate.
            // The df crate's internal loops sometimes access index NB_FREQS
            // (= FFT_SIZE/2 + 1 = 481) which is out of bounds for a Vec of
            // length 481. Adding one extra element (zero-initialized) prevents
            // the panic without affecting DSP correctness (the extra bin is
            // never used in the output).
            spec_buf: vec![Complex32::new(0.0, 0.0); NB_FREQS + 1],
            erb_buf: vec![0.0f32; NB_ERB],
            intensity: 0.6,
            active: AtomicBool::new(true),
        })
    })();

    match result {
        Ok(engine) => {
            let mutex = get_engine_mutex();
            *mutex.lock().unwrap() = Some(engine);
            info!("dfn3_init: engine ready");
            true
        }
        Err(e) => {
            error!("dfn3_init: failed: {}", e);
            false
        }
    }
}

// ─── Processing ──────────────────────────────────────────────────────────────

/// Process one audio hop (480 samples @ 48 kHz) in-place.
///
/// # Safety
/// `buffer` must point to at least HOP_SIZE (480) writable f32s.
#[no_mangle]
pub unsafe extern "C" fn dfn3_process_hop(buffer: *mut f32) -> bool {
    if buffer.is_null() {
        return false;
    }

    let mutex = get_engine_mutex();
    let mut guard = match mutex.try_lock() {
        Ok(g) => g,
        Err(_) => return false,
    };

    let engine = match guard.as_mut() {
        Some(e) if e.active.load(Ordering::Acquire) => e,
        _ => return false,
    };

    let audio = std::slice::from_raw_parts_mut(buffer, HOP_SIZE);
    let intensity = engine.intensity;

    if intensity <= 0.0 {
        return true;
    }

    let mut dry = [0.0f32; HOP_SIZE];
    dry.copy_from_slice(audio);

    match process_frame(engine, audio) {
        Ok(()) => {
            if intensity < 1.0 {
                for i in 0..HOP_SIZE {
                    audio[i] = dry[i] * (1.0 - intensity) + audio[i] * intensity;
                }
            }
            for s in audio.iter_mut() {
                *s = s.clamp(-1.0, 1.0);
            }
            true
        }
        Err(e) => {
            warn!("dfn3_process_hop: failed: {}", e);
            audio.copy_from_slice(&dry);
            false
        }
    }
}

fn process_frame(
    engine: &mut Dfn3Engine,
    audio: &mut [f32],
) -> Result<(), Box<dyn std::error::Error>> {
    // 1. STFT analysis: audio → complex spectrum
    engine.df_state.analysis(audio, &mut engine.spec_buf);

    // 2. Extract ERB features from spectrum
    let alpha = 0.98f32; // smoothing factor
    // The spec_buf is allocated with NB_FREQS + 1 elements to prevent
    // off-by-one panic in the df crate. See Dfn3Engine construction above.
    engine.df_state.feat_erb(&engine.spec_buf, alpha, &mut engine.erb_buf);

    // 3. Prepare encoder input tensor [1, NB_ERB]
    let erb_tensor: Tensor = tract_ndarray::Array2::from_shape_vec(
        (1, NB_ERB),
        engine.erb_buf.clone(),
    )?
    .into();

    // 4. Run encoder
    let enc_out = engine.enc.run(tvec![erb_tensor.into()])?;

    // 5. ERB decoder → gains [1, NB_ERB]
    let erb_gains_out = engine.erb_dec.run(tvec![enc_out[0].clone()])?;
    let erb_gains = erb_gains_out[0].to_array_view::<f32>()?;
    let gains_slice = erb_gains.as_slice().unwrap();

    // 6. Apply mask/gains to spectrum
    //    apply_mask interpolates ERB-band gains to full frequency resolution
    engine.df_state.apply_mask(&mut engine.spec_buf, gains_slice);

    // 7. iSTFT synthesis: complex spectrum → audio
    engine.df_state.synthesis(&mut engine.spec_buf, audio);

    Ok(())
}

// ─── Control API ─────────────────────────────────────────────────────────────

#[no_mangle]
pub unsafe extern "C" fn dfn3_set_intensity(intensity: f32) {
    let mutex = get_engine_mutex();
    if let Ok(mut guard) = mutex.lock() {
        if let Some(engine) = guard.as_mut() {
            engine.intensity = intensity.clamp(0.0, 1.0);
        }
    }
}

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

#[no_mangle]
pub unsafe extern "C" fn dfn3_free() {
    let mutex = get_engine_mutex();
    if let Ok(mut guard) = mutex.lock() {
        *guard = None;
        info!("dfn3_free: engine released");
    }
}
