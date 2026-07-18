//! DeepFilterNet3 speech enhancement — C FFI wrapper for Android.
//!
//! Uses the upstream `df` crate (DfTract + DfParams) which handles:
//!   - Loading 3 ONNX models from a .tar.gz archive
//!   - Pulsed-model transformation via tract for streaming
//!   - STFT/iSTFT, ERB filterbank, deep filtering
//!   - Frame-by-frame stateful inference
//!
//! This file only exposes a C API for the C++ audio engine.

use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::Mutex;

use log::{error, info, warn};
use ndarray::{Array2, ArrayView2};
use once_cell::sync::OnceCell;

use df::tract::*;

/// Hop size: 480 samples @ 48 kHz = 10 ms.
pub const HOP_SIZE: usize = 480;

struct Dfn3Engine {
    model: DfTract,
    intensity: f32,
    enh_buf: Array2<f32>,
}

static ENGINE: OnceCell<Mutex<Option<Dfn3Engine>>> = OnceCell::new();

fn get_mutex() -> &'static Mutex<Option<Dfn3Engine>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

#[no_mangle]
pub unsafe extern "C" fn dfn3_init(model_path: *const c_char) -> bool {
    #[cfg(target_os = "android")]
    {
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Info)
                .with_tag("DFN3"),
        );
    }

    if model_path.is_null() {
        error!("dfn3_init: path is null");
        return false;
    }

    let path_str = match CStr::from_ptr(model_path).to_str() {
        Ok(s) => s,
        Err(e) => {
            error!("dfn3_init: invalid UTF-8: {}", e);
            return false;
        }
    };

    info!("dfn3_init: loading from {}", path_str);

    let result = (|| -> anyhow::Result<Dfn3Engine> {
        let params = DfParams::new(PathBuf::from(path_str))?;
        let r_params = RuntimeParams::default_with_ch(1);
        let model = DfTract::new(params, &r_params)?;
        let hop = model.hop_size;
        info!("dfn3_init: ok (sr={}, hop={}, erb={}, df={})",
              model.sr, hop, model.nb_erb, model.nb_df);
        let enh_buf = Array2::<f32>::zeros((1, hop));
        Ok(Dfn3Engine { model, intensity: 0.6, enh_buf })
    })();

    match result {
        Ok(engine) => {
            *get_mutex().lock().unwrap() = Some(engine);
            true
        }
        Err(e) => {
            error!("dfn3_init: failed: {:?}", e);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dfn3_process_hop(buffer: *mut f32) -> bool {
    if buffer.is_null() { return false; }

    let mut guard = match get_mutex().try_lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    let engine = match guard.as_mut() {
        Some(e) => e,
        None => return false,
    };

    let hop = engine.model.hop_size;
    let audio = std::slice::from_raw_parts_mut(buffer, hop);
    let intensity = engine.intensity;

    if intensity <= 0.0 { return true; }

    let mut dry = vec![0.0f32; hop];
    dry.copy_from_slice(audio);

    let noisy = ArrayView2::from_shape((1, hop), &dry).unwrap();
    engine.enh_buf.fill(0.0);

    match engine.model.process(noisy, engine.enh_buf.view_mut()) {
        Ok(_) => {
            let enh = engine.enh_buf.as_slice().unwrap();
            if intensity >= 1.0 {
                audio.copy_from_slice(enh);
            } else {
                for i in 0..hop {
                    audio[i] = dry[i] * (1.0 - intensity) + enh[i] * intensity;
                }
            }
            for s in audio.iter_mut() { *s = s.clamp(-1.0, 1.0); }
            true
        }
        Err(e) => {
            warn!("process error: {:?}", e);
            audio.copy_from_slice(&dry);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dfn3_set_intensity(intensity: f32) {
    if let Ok(mut g) = get_mutex().lock() {
        if let Some(e) = g.as_mut() { e.intensity = intensity.clamp(0.0, 1.0); }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dfn3_get_intensity() -> f32 {
    if let Ok(g) = get_mutex().lock() {
        if let Some(e) = g.as_ref() { return e.intensity; }
    }
    0.6
}

#[no_mangle]
pub unsafe extern "C" fn dfn3_is_active() -> bool {
    if let Ok(g) = get_mutex().lock() { return g.is_some(); }
    false
}

#[no_mangle]
pub unsafe extern "C" fn dfn3_free() {
    if let Ok(mut g) = get_mutex().lock() { *g = None; }
}
