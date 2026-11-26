//! Image thumbnail, preview, and ThumbHash generation (`image.thumb`), extracted from
//! `station/native/mesh/src/thumbs.rs` (zero N-API) for `stillfail-shell` station builds.
//!
//! Supports PNG, JPEG, and WebP inputs (from file `path` or raw `bytes`), EXIF orientation,
//! CatmullRom resampling, alpha-aware PNG / JPEG / lossless-WebP encoding, and base64 ThumbHash,
//! with strict parameter validation and decompression-bomb limits.

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::{Answer, Done, err};

/// Maximum accepted input size in bytes (64 MiB).
pub(crate) const MAX_INPUT_BYTES: u64 = 64 * 1024 * 1024;
/// Maximum accepted decoded image width or height (32768 px; covers tall screenshots while bounding allocations).
pub(crate) const MAX_DECODE_DIM: u32 = 32_768;
/// Maximum accepted decoded pixel count (32 MP -> at most 128 MiB RGBA8).
pub(crate) const MAX_DECODE_PIXELS: u64 = 32 * 1024 * 1024;
/// Maximum memory allocation allowed inside `image` decoders (128 MiB).
pub(crate) const MAX_DECODE_ALLOC: u64 = 128 * 1024 * 1024;
/// Maximum requested output width, height, minShort, or maxLong (matches `thumbs.rs` `max_long`).
pub(crate) const MAX_TARGET_DIM: u32 = 8192;
/// Maximum size-savings ratio multiplier (`out.len() * ratio < input_len`).
pub(crate) const MAX_RATIO: u64 = 16;

/// Default JPEG quality (matches `thumbs.rs` `jpeg`: high enough that small text keeps its edges).
const DEFAULT_QUALITY: u8 = 88;
/// Chat thumbnail constants (matches `thumbs.rs`).
const MAX_W: u32 = 720;
const MAX_H: u32 = 600;
const SMALL: u64 = 24 * 1024;
const PREVIEW_MAX: u32 = 2048;
const PREVIEW_SMALL: u64 = 300 * 1024;

static PART_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Thumb,
    Box,
    Preview,
    Hash,
    Custom,
}

#[derive(Debug, Clone)]
struct SizeSpec {
    max_w: u32,
    max_h: u32,
    min_short: u32,
    max_long: u32,
    suffix: &'static str,
    ratio: u64,
    lossless: bool,
    quality: u8,
    small_bytes: u64,
}

#[derive(Debug)]
enum Input {
    Path(PathBuf),
    Bytes(Vec<u8>),
}

#[derive(Debug)]
struct Request {
    input: Input,
    mode: Mode,
    spec: Option<SizeSpec>,
    thumbhash: bool,
    dir: Option<PathBuf>,
}

const ALLOWED_KEYS: &[&str] = &[
    "path",
    "mode",
    "maxWidth",
    "maxHeight",
    "minShort",
    "maxLong",
    "quality",
    "lossless",
    "ratio",
    "smallBytes",
    "thumbhash",
    "dir",
];

fn opt_u32(obj: &Map<String, Value>, key: &str, min: u32, max: u32) -> Result<Option<u32>, String> {
    let Some(v) = obj.get(key) else {
        return Ok(None);
    };
    let n = v.as_u64().ok_or_else(|| format!("{key} must be an integer in {min}..={max}"))?;
    if n < min as u64 || n > max as u64 {
        return Err(format!("{key} must be in {min}..={max}, got {n}"));
    }
    Ok(Some(n as u32))
}

fn opt_u64(obj: &Map<String, Value>, key: &str, min: u64, max: u64) -> Result<Option<u64>, String> {
    let Some(v) = obj.get(key) else {
        return Ok(None);
    };
    let n = v.as_u64().ok_or_else(|| format!("{key} must be an integer in {min}..={max}"))?;
    if n < min || n > max {
        return Err(format!("{key} must be in {min}..={max}, got {n}"));
    }
    Ok(Some(n))
}

fn opt_bool(obj: &Map<String, Value>, key: &str) -> Result<Option<bool>, String> {
    let Some(v) = obj.get(key) else {
        return Ok(None);
    };
    v.as_bool().map(Some).ok_or_else(|| format!("{key} must be a boolean"))
}

fn opt_non_empty_path(obj: &Map<String, Value>, key: &str) -> Result<Option<PathBuf>, String> {
    let Some(v) = obj.get(key) else {
        return Ok(None);
    };
    let s = v.as_str().ok_or_else(|| format!("{key} must be a string"))?;
    if s.is_empty() {
        return Err(format!("{key} must not be empty"));
    }
    if s.contains('\0') {
        return Err(format!("{key} must not contain NUL"));
    }
    Ok(Some(PathBuf::from(s)))
}

fn parse_request(a: &Value, bytes: Option<Vec<u8>>) -> Result<Request, String> {
    let obj = a.as_object().ok_or_else(|| "image.thumb arguments must be a JSON object".to_string())?;
    for key in obj.keys() {
        if !ALLOWED_KEYS.contains(&key.as_str()) {
            return Err(format!("unknown parameter: {key}"));
        }
    }

    let path = opt_non_empty_path(obj, "path")?;
    let input = match (path, bytes) {
        (Some(_), Some(_)) => return Err("provide either path or bytes, not both".into()),
        (None, None) => return Err("missing path or bytes".into()),
        (Some(p), None) => Input::Path(p),
        (None, Some(b)) => {
            if b.is_empty() {
                return Err("input bytes must not be empty".into());
            }
            if b.len() as u64 > MAX_INPUT_BYTES {
                return Err(format!("input bytes exceed maximum size of {MAX_INPUT_BYTES} bytes"));
            }
            Input::Bytes(b)
        }
    };

    let mode_str = obj
        .get("mode")
        .and_then(Value::as_str)
        .ok_or_else(|| "mode must be one of: thumb, box, preview, hash, custom".to_string())?;
    let mode = match mode_str {
        "thumb" => Mode::Thumb,
        "box" => Mode::Box,
        "preview" => Mode::Preview,
        "hash" => Mode::Hash,
        "custom" => Mode::Custom,
        other => return Err(format!("invalid mode: {other}")),
    };

    let dir = opt_non_empty_path(obj, "dir")?;
    if dir.is_some() {
        if !matches!(input, Input::Path(_)) {
            return Err("dir requires path input".into());
        }
        if matches!(mode, Mode::Hash | Mode::Custom) {
            return Err(format!("dir is not supported with mode {mode_str}"));
        }
    }

    let max_width = opt_u32(obj, "maxWidth", 1, MAX_TARGET_DIM)?;
    let max_height = opt_u32(obj, "maxHeight", 1, MAX_TARGET_DIM)?;
    let min_short = opt_u32(obj, "minShort", 0, MAX_TARGET_DIM)?;
    let max_long = opt_u32(obj, "maxLong", 0, MAX_TARGET_DIM)?;
    let quality = opt_u32(obj, "quality", 1, 100)?.map(|q| q as u8);
    let lossless = opt_bool(obj, "lossless")?;
    let ratio = opt_u64(obj, "ratio", 0, MAX_RATIO)?;
    let small_bytes = opt_u64(obj, "smallBytes", 0, MAX_INPUT_BYTES)?;
    let thumbhash_opt = opt_bool(obj, "thumbhash")?;

    if mode == Mode::Hash {
        if max_width.is_some()
            || max_height.is_some()
            || min_short.is_some()
            || max_long.is_some()
            || quality.is_some()
            || lossless.is_some()
            || ratio.is_some()
            || small_bytes.is_some()
        {
            return Err("sizing and encoding parameters are not allowed with mode hash".into());
        }
        if thumbhash_opt == Some(false) {
            return Err("thumbhash cannot be false with mode hash".into());
        }
        return Ok(Request { input, mode, spec: None, thumbhash: true, dir: None });
    }

    if dir.is_some()
        && (max_width.is_some()
            || max_height.is_some()
            || min_short.is_some()
            || max_long.is_some()
            || quality.is_some()
            || lossless.is_some()
            || ratio.is_some())
    {
        return Err("custom sizing and encoding overrides are not allowed with dir cache".into());
    }

    let base = match mode {
        Mode::Thumb => SizeSpec {
            max_w: MAX_W,
            max_h: MAX_H,
            min_short: 320,
            max_long: 8192,
            suffix: "",
            ratio: 1,
            lossless: false,
            quality: DEFAULT_QUALITY,
            small_bytes: SMALL,
        },
        Mode::Box => SizeSpec {
            max_w: MAX_W,
            max_h: MAX_H,
            min_short: 0,
            max_long: 0,
            suffix: ".b",
            ratio: 1,
            lossless: false,
            quality: DEFAULT_QUALITY,
            small_bytes: SMALL,
        },
        Mode::Preview => SizeSpec {
            max_w: PREVIEW_MAX,
            max_h: PREVIEW_MAX,
            min_short: 0,
            max_long: 0,
            suffix: ".p",
            ratio: 2,
            lossless: true,
            quality: DEFAULT_QUALITY,
            small_bytes: PREVIEW_SMALL,
        },
        Mode::Custom => {
            let mw = max_width.ok_or_else(|| "mode custom requires maxWidth".to_string())?;
            let mh = max_height.ok_or_else(|| "mode custom requires maxHeight".to_string())?;
            SizeSpec {
                max_w: mw,
                max_h: mh,
                min_short: 0,
                max_long: 0,
                suffix: "",
                ratio: 0,
                lossless: false,
                quality: DEFAULT_QUALITY,
                small_bytes: 0,
            }
        }
        Mode::Hash => unreachable!(),
    };

    let spec = SizeSpec {
        max_w: max_width.unwrap_or(base.max_w),
        max_h: max_height.unwrap_or(base.max_h),
        min_short: min_short.unwrap_or(base.min_short),
        max_long: max_long.unwrap_or(base.max_long),
        suffix: base.suffix,
        ratio: ratio.unwrap_or(base.ratio),
        lossless: lossless.unwrap_or(base.lossless),
        quality: quality.unwrap_or(base.quality),
        small_bytes: small_bytes.unwrap_or(base.small_bytes),
    };

    if spec.min_short > 0 && spec.max_long == 0 {
        return Err("minShort > 0 requires maxLong > 0".into());
    }
    if spec.min_short > 0 && spec.min_short > spec.max_long {
        return Err("minShort must not exceed maxLong".into());
    }

    Ok(Request {
        input,
        mode,
        spec: Some(spec),
        thumbhash: thumbhash_opt.unwrap_or(false),
        dir,
    })
}

fn id_of_path(path: &Path) -> String {
    hex::encode(&Sha256::digest(path.to_string_lossy().as_bytes())[..16])
}

fn kept(dir: &Path, id: &str, suffix: &str) -> Option<(PathBuf, &'static str)> {
    [("jpg", "image/jpeg"), ("png", "image/png"), ("webp", "image/webp")]
        .into_iter()
        .map(|(ext, kind)| (dir.join(format!("{id}{suffix}.{ext}")), kind))
        .find(|(path, _)| path.is_file())
}

fn read_input_file(path: &Path) -> Result<(Vec<u8>, u64), String> {
    let pre = std::fs::metadata(path).map_err(|e| format!("cannot stat input: {e}"))?;
    if !pre.is_file() {
        return Err("input path is not a regular file".into());
    }
    if pre.len() == 0 {
        return Err("input file is empty".into());
    }
    if pre.len() > MAX_INPUT_BYTES {
        return Err(format!("input file exceeds maximum size of {MAX_INPUT_BYTES} bytes"));
    }
    let file = std::fs::File::open(path).map_err(|e| format!("cannot open input: {e}"))?;
    let meta = file.metadata().map_err(|e| format!("cannot stat open input: {e}"))?;
    if !meta.is_file() {
        return Err("input path is not a regular file".into());
    }
    let mut buf = Vec::with_capacity(meta.len().min(MAX_INPUT_BYTES) as usize);
    file.take(MAX_INPUT_BYTES + 1)
        .read_to_end(&mut buf)
        .map_err(|e| format!("cannot read input: {e}"))?;
    if buf.is_empty() {
        return Err("input file is empty".into());
    }
    if buf.len() as u64 > MAX_INPUT_BYTES {
        return Err(format!("input file exceeds maximum size of {MAX_INPUT_BYTES} bytes"));
    }
    let len = buf.len() as u64;
    Ok((buf, len))
}

fn decode_image(raw: &[u8]) -> Result<DynamicImage, String> {
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_DECODE_DIM);
    limits.max_image_height = Some(MAX_DECODE_DIM);
    limits.max_alloc = Some(MAX_DECODE_ALLOC);

    let mut reader = ImageReader::new(Cursor::new(raw))
        .with_guessed_format()
        .map_err(|e| format!("cannot detect image format: {e}"))?;
    reader.limits(limits);

    let format = reader.format().ok_or_else(|| "unsupported or unknown image format".to_string())?;
    if !matches!(format, ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::WebP) {
        return Err(format!("unsupported image format: {format:?}"));
    }

    let mut decoder = reader.into_decoder().map_err(|e| format!("image decode init failed: {e}"))?;
    let (dw, dh) = decoder.dimensions();
    if dw == 0 || dh == 0 {
        return Err("image has zero dimensions".into());
    }
    if dw > MAX_DECODE_DIM || dh > MAX_DECODE_DIM {
        return Err(format!("image dimensions {dw}x{dh} exceed limit {MAX_DECODE_DIM}"));
    }
    let pixels = (dw as u64).checked_mul(dh as u64).ok_or_else(|| "image pixel count overflow".to_string())?;
    if pixels > MAX_DECODE_PIXELS {
        return Err(format!("image pixel count {pixels} exceeds limit {MAX_DECODE_PIXELS}"));
    }

    let orientation = decoder.orientation().ok();
    let mut decoded = DynamicImage::from_decoder(decoder).map_err(|e| format!("image decode failed: {e}"))?;
    if let Some(orientation) = orientation {
        decoded.apply_orientation(orientation);
    }
    Ok(decoded)
}

fn encode_png(image: &DynamicImage) -> Result<Vec<u8>, String> {
    let mut out = Cursor::new(Vec::new());
    image.write_to(&mut out, ImageFormat::Png).map_err(|e| format!("png encode failed: {e}"))?;
    Ok(out.into_inner())
}

fn encode_webp(image: &DynamicImage, clear: bool) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let encoder = image::codecs::webp::WebPEncoder::new_lossless(&mut out);
    if clear {
        image.to_rgba8().write_with_encoder(encoder).map_err(|e| format!("webp encode failed: {e}"))?;
    } else {
        image.to_rgb8().write_with_encoder(encoder).map_err(|e| format!("webp encode failed: {e}"))?;
    }
    Ok(out)
}

fn encode_jpeg(image: &DynamicImage, quality: u8) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    image
        .to_rgb8()
        .write_with_encoder(JpegEncoder::new_with_quality(&mut out, quality))
        .map_err(|e| format!("jpeg encode failed: {e}"))?;
    Ok(out)
}

fn compute_thumbhash(image: &DynamicImage) -> String {
    let small = image.thumbnail(100, 100).to_rgba8();
    let bytes = thumbhash::rgba_to_thumb_hash(small.width() as usize, small.height() as usize, small.as_raw());
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn resize_for(decoded: DynamicImage, spec: &SizeSpec) -> DynamicImage {
    let (ow, oh) = (decoded.width(), decoded.height());
    if ow <= spec.max_w && oh <= spec.max_h {
        return decoded;
    }
    let fit_k = (spec.max_w as f64 / ow as f64).min(spec.max_h as f64 / oh as f64);
    let short = ow.min(oh) as f64;
    let long = ow.max(oh) as f64;
    if spec.min_short > 0 && short * fit_k < spec.min_short as f64 {
        let short_k = (spec.min_short as f64 / short).min(1.0);
        let long_cap_k = if spec.max_long > 0 { (spec.max_long as f64 / long).min(1.0) } else { 1.0 };
        let k = fit_k.max(short_k.min(long_cap_k));
        if k < 1.0 {
            let nw = (ow as f64 * k).round().max(1.0) as u32;
            let nh = (oh as f64 * k).round().max(1.0) as u32;
            decoded.resize_exact(nw, nh, FilterType::CatmullRom)
        } else {
            decoded
        }
    } else {
        decoded.resize(spec.max_w, spec.max_h, FilterType::CatmullRom)
    }
}

fn write_atomic(dir: &Path, id: &str, suffix: &str, ext: &str, bytes: &[u8]) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create thumb dir: {e}"))?;
    let path = dir.join(format!("{id}{suffix}.{ext}"));
    let seq = PART_SEQ.fetch_add(1, Ordering::Relaxed);
    let partial = dir.join(format!("{id}{suffix}.{ext}.{}.{seq}.part", std::process::id()));
    if let Err(e) = std::fs::write(&partial, bytes) {
        let _ = std::fs::remove_file(&partial);
        return Err(format!("cannot write thumb: {e}"));
    }
    if let Err(e) = std::fs::rename(&partial, &path) {
        let _ = std::fs::remove_file(&partial);
        return Err(format!("cannot rename thumb: {e}"));
    }
    Ok(path)
}

fn execute(req: Request) -> Done {
    // Fast path for path-backed small-file skip and cache hit when thumbhash is not requested.
    if let (Input::Path(path), Some(spec)) = (&req.input, &req.spec)
        && !req.thumbhash
    {
        let meta = std::fs::metadata(path).map_err(|e| format!("cannot stat input: {e}"))?;
        if !meta.is_file() {
            return Err("input path is not a regular file".into());
        }
        let len = meta.len();
        if len == 0 {
            return Err("input file is empty".into());
        }
        if len > MAX_INPUT_BYTES {
            return Err(format!("input file exceeds maximum size of {MAX_INPUT_BYTES} bytes"));
        }
        if spec.small_bytes > 0 && len <= spec.small_bytes {
            return Ok(Answer::json(json!({ "skipped": true, "reason": "small" })));
        }
        if let Some(dir) = &req.dir {
            let id = id_of_path(path);
            if let Some((found, kind)) = kept(dir, &id, spec.suffix) {
                return Ok(Answer::json(json!({
                    "skipped": false,
                    "cached": true,
                    "path": found.to_string_lossy(),
                    "mime": kind,
                })));
            }
        }
    }

    let owned_raw;
    let (raw, input_len): (&[u8], u64) = match &req.input {
        Input::Path(path) => {
            let (buf, len) = read_input_file(path)?;
            owned_raw = buf;
            (&owned_raw, len)
        }
        Input::Bytes(b) => {
            if let Some(spec) = &req.spec
                && !req.thumbhash
                && spec.small_bytes > 0
                && (b.len() as u64) <= spec.small_bytes
            {
                return Ok(Answer::json(json!({ "skipped": true, "reason": "small" })));
            }
            (b.as_slice(), b.len() as u64)
        }
    };

    let decoded = decode_image(raw)?;
    let (ow, oh) = (decoded.width(), decoded.height());
    let hash = if req.thumbhash { Some(compute_thumbhash(&decoded)) } else { None };

    if req.mode == Mode::Hash {
        return Ok(Answer::json(json!({
            "thumbhash": hash.expect("hash mode always computes thumbhash"),
            "width": ow,
            "height": oh,
        })));
    }

    let spec = req.spec.as_ref().expect("non-hash mode has size spec");
    if spec.small_bytes > 0 && input_len <= spec.small_bytes {
        let mut out = json!({
            "skipped": true,
            "reason": "small",
            "originalWidth": ow,
            "originalHeight": oh,
        });
        if let Some(h) = hash {
            out["thumbhash"] = Value::String(h);
        }
        return Ok(Answer::json(out));
    }

    // If dir cache hit happened while thumbhash was requested, return cached path + fresh hash/dimensions.
    if let (Input::Path(path), Some(dir)) = (&req.input, &req.dir) {
        let id = id_of_path(path);
        if let Some((found, kind)) = kept(dir, &id, spec.suffix) {
            let mut out = json!({
                "skipped": false,
                "cached": true,
                "path": found.to_string_lossy(),
                "mime": kind,
                "originalWidth": ow,
                "originalHeight": oh,
            });
            if let Some(h) = hash {
                out["thumbhash"] = Value::String(h);
            }
            return Ok(Answer::json(out));
        }
    }

    let small = resize_for(decoded, spec);
    let (tw, th) = (small.width(), small.height());
    let clear = small.color().has_alpha() && small.to_rgba8().pixels().any(|p| p.0[3] < 255);
    let (mut ext, mut kind, mut encoded) = if clear {
        ("png", "image/png", encode_png(&small)?)
    } else {
        ("jpg", "image/jpeg", encode_jpeg(&small, spec.quality)?)
    };
    if spec.lossless {
        let exact = encode_webp(&small, clear)?;
        if exact.len() < encoded.len() {
            (ext, kind, encoded) = ("webp", "image/webp", exact);
        }
    }

    if spec.ratio > 0 && (encoded.len() as u64).saturating_mul(spec.ratio) >= input_len {
        let mut out = json!({
            "skipped": true,
            "reason": "not_smaller",
            "originalWidth": ow,
            "originalHeight": oh,
        });
        if let Some(h) = hash {
            out["thumbhash"] = Value::String(h);
        }
        return Ok(Answer::json(out));
    }

    let mut out = json!({
        "skipped": false,
        "mime": kind,
        "width": tw,
        "height": th,
        "originalWidth": ow,
        "originalHeight": oh,
        "size": encoded.len(),
    });
    if let Some(h) = hash {
        out["thumbhash"] = Value::String(h);
    }

    if let (Input::Path(path), Some(dir)) = (&req.input, &req.dir) {
        let id = id_of_path(path);
        let written = write_atomic(dir, &id, spec.suffix, ext, &encoded)?;
        out["cached"] = Value::Bool(false);
        out["path"] = Value::String(written.to_string_lossy().into_owned());
        Ok(Answer::json(out))
    } else {
        Ok(Answer::bytes(out, encoded))
    }
}

pub(crate) async fn run(a: Value, bytes: Option<Vec<u8>>) -> Done {
    let req = parse_request(&a, bytes)?;
    tokio::task::spawn_blocking(move || execute(req)).await.map_err(err)?
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb, Rgba};

    struct TempDir(PathBuf);
    impl TempDir {
        fn new(tag: &str) -> Self {
            static N: AtomicU64 = AtomicU64::new(0);
            let dir = std::env::temp_dir().join(format!(
                "stillfail-image-thumb-{tag}-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            TempDir(dir)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn make_noisy_rgb_png(w: u32, h: u32) -> Vec<u8> {
        let mut img = ImageBuffer::<Rgb<u8>, Vec<u8>>::new(w, h);
        let mut s: u64 = 0x9e37_79b9_7f4a_7c15;
        for (_, _, p) in img.enumerate_pixels_mut() {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let r = (s >> 56) as u8;
            let g = (s >> 48) as u8;
            let b = (s >> 40) as u8;
            *p = Rgb([r, g, b]);
        }
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(img).write_to(&mut out, ImageFormat::Png).unwrap();
        out.into_inner()
    }

    fn make_alpha_png(w: u32, h: u32, transparent: bool) -> Vec<u8> {
        let mut img = ImageBuffer::<Rgba<u8>, Vec<u8>>::new(w, h);
        for (x, y, p) in img.enumerate_pixels_mut() {
            let a = if transparent && x < w / 2 { 128 } else { 255 };
            *p = Rgba([((x * 7) % 256) as u8, ((y * 13) % 256) as u8, (((x ^ y) * 3) % 256) as u8, a]);
        }
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(img).write_to(&mut out, ImageFormat::Png).unwrap();
        out.into_inner()
    }

    fn make_flat_screenshot_png(w: u32, h: u32) -> Vec<u8> {
        let mut img = ImageBuffer::<Rgb<u8>, Vec<u8>>::new(w, h);
        for (x, y, p) in img.enumerate_pixels_mut() {
            if (x / 40 + y / 40) % 2 == 0 {
                *p = Rgb([250, 250, 252]);
            } else {
                *p = Rgb([20, 24, 30]);
            }
        }
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(img).write_to(&mut out, ImageFormat::Png).unwrap();
        out.into_inner()
    }

    /// Injects an EXIF APP1 segment with Orientation = `orientation` (1..=8) right after the JPEG SOI marker.
    fn make_jpeg_with_exif_orientation(w: u32, h: u32, orientation: u16) -> Vec<u8> {
        let mut img = ImageBuffer::<Rgb<u8>, Vec<u8>>::new(w, h);
        for (x, y, p) in img.enumerate_pixels_mut() {
            // Distinct quadrant colors so orientation transform is verifiable.
            *p = if x < w / 2 && y < h / 2 {
                Rgb([240, 30, 30]) // top-left: red
            } else if x >= w / 2 && y < h / 2 {
                Rgb([30, 240, 30]) // top-right: green
            } else if x < w / 2 {
                Rgb([30, 30, 240]) // bottom-left: blue
            } else {
                Rgb([240, 240, 30]) // bottom-right: yellow
            };
        }
        let mut raw_jpg = Vec::new();
        DynamicImage::ImageRgb8(img)
            .to_rgb8()
            .write_with_encoder(JpegEncoder::new_with_quality(&mut raw_jpg, 95))
            .unwrap();
        assert_eq!(&raw_jpg[0..2], &[0xFF, 0xD8]);

        // Minimal little-endian TIFF EXIF with 1 IFD0 entry: tag 0x0112 (Orientation), SHORT, count 1.
        let mut exif = Vec::new();
        exif.extend_from_slice(b"Exif\0\0");
        exif.extend_from_slice(b"II"); // little-endian
        exif.extend_from_slice(&42u16.to_le_bytes());
        exif.extend_from_slice(&8u32.to_le_bytes()); // IFD0 offset
        exif.extend_from_slice(&1u16.to_le_bytes()); // 1 entry
        exif.extend_from_slice(&0x0112u16.to_le_bytes()); // Orientation tag
        exif.extend_from_slice(&3u16.to_le_bytes()); // SHORT
        exif.extend_from_slice(&1u32.to_le_bytes()); // count = 1
        exif.extend_from_slice(&orientation.to_le_bytes());
        exif.extend_from_slice(&0u16.to_le_bytes()); // padding
        exif.extend_from_slice(&0u32.to_le_bytes()); // next IFD = 0

        let seg_len = (exif.len() + 2) as u16;
        let mut out = Vec::with_capacity(raw_jpg.len() + exif.len() + 4);
        out.extend_from_slice(&raw_jpg[0..2]); // SOI
        out.extend_from_slice(&[0xFF, 0xE1]); // APP1
        out.extend_from_slice(&seg_len.to_be_bytes());
        out.extend_from_slice(&exif);
        out.extend_from_slice(&raw_jpg[2..]);
        out
    }

    /// Builds a minimal synthetic PNG header claiming arbitrary dimensions `w x h` (for decompression-bomb testing).
    fn make_fake_png_header(w: u32, h: u32) -> Vec<u8> {
        fn crc32(data: &[u8]) -> u32 {
            let mut crc: u32 = 0xFFFF_FFFF;
            for &b in data {
                crc ^= b as u32;
                for _ in 0..8 {
                    let mask = (crc & 1).wrapping_neg();
                    crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
                }
            }
            !crc
        }
        let mut out = Vec::new();
        out.extend_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]); // PNG signature
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(b"IHDR");
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit RGBA, deflate, filter 0, non-interlaced
        out.extend_from_slice(&13u32.to_be_bytes());
        out.extend_from_slice(&ihdr);
        out.extend_from_slice(&crc32(&ihdr).to_be_bytes());
        // Empty IEND
        out.extend_from_slice(&0u32.to_be_bytes());
        out.extend_from_slice(b"IEND");
        out.extend_from_slice(&crc32(b"IEND").to_be_bytes());
        out
    }

    #[test]
    fn rejects_invalid_parameters() {
        let png = make_noisy_rgb_png(64, 64);

        // Non-object JSON
        assert!(parse_request(&json!(null), Some(png.clone())).is_err());
        assert!(parse_request(&json!([]), Some(png.clone())).is_err());

        // Unknown key
        assert!(parse_request(&json!({ "mode": "hash", "max_width": 100 }), Some(png.clone())).is_err());

        // Missing or conflicting input
        assert!(parse_request(&json!({ "mode": "hash" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "/tmp/a.png" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "/tmp/a\0b.png" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "hash" }), Some(Vec::new())).is_err());

        // Missing or invalid mode
        assert!(parse_request(&json!({}), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "bogus" }), Some(png.clone())).is_err());

        // Custom mode requires explicit maxWidth and maxHeight
        assert!(parse_request(&json!({ "mode": "custom" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxHeight": 100 }), Some(png.clone())).is_err());

        // Out-of-range or wrong-type dimensions / quality / ratio
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 0, "maxHeight": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 8193, "maxHeight": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": -5, "maxHeight": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100.5, "maxHeight": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": "100", "maxHeight": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100, "maxHeight": 100, "quality": 0 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100, "maxHeight": 100, "quality": 101 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100, "maxHeight": 100, "ratio": 17 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100, "maxHeight": 100, "minShort": 500, "maxLong": 0 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100, "maxHeight": 100, "minShort": 500, "maxLong": 400 }), Some(png.clone())).is_err());

        // Hash mode rejects sizing/encoding params and thumbhash=false
        assert!(parse_request(&json!({ "mode": "hash", "maxWidth": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "thumbhash": false }), Some(png.clone())).is_err());

        // Dir cache constraints
        assert!(parse_request(&json!({ "mode": "thumb", "dir": "/tmp/t" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "/tmp/a.png", "dir": "/tmp/t" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "path": "/tmp/a.png", "dir": "/tmp/t", "maxWidth": 100, "maxHeight": 100 }), None).is_err());
        assert!(parse_request(&json!({ "mode": "thumb", "path": "/tmp/a.png", "dir": "/tmp/t", "maxWidth": 100 }), None).is_err());
    }

    #[test]
    fn rejects_decompression_bombs_and_corrupt_inputs() {
        // 25000 x 25000 = 625 MP > MAX_DECODE_PIXELS (32 MP)
        let bomb_pixels = make_fake_png_header(25_000, 25_000);
        let err = execute(parse_request(&json!({ "mode": "hash" }), Some(bomb_pixels)).unwrap())
            .err()
            .expect("pixel bomb must be rejected");
        assert!(err.contains("limit") || err.contains("exceed") || err.contains("decode"), "unexpected err: {err}");

        // 40000 x 10 exceeds MAX_DECODE_DIM (32768)
        let bomb_dim = make_fake_png_header(40_000, 10);
        let err = execute(parse_request(&json!({ "mode": "hash" }), Some(bomb_dim)).unwrap())
            .err()
            .expect("dim bomb must be rejected");
        assert!(err.contains("limit") || err.contains("exceed") || err.contains("decode"), "unexpected err: {err}");

        // Unsupported format (GIF89a)
        let gif = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;".to_vec();
        assert!(execute(parse_request(&json!({ "mode": "hash" }), Some(gif)).unwrap()).is_err());

        // Garbage bytes
        assert!(execute(parse_request(&json!({ "mode": "hash" }), Some(b"not an image".to_vec())).unwrap()).is_err());

        // Non-regular file (directory) & missing file
        let tmp = TempDir::new("nonfile");
        assert!(execute(parse_request(&json!({ "mode": "hash", "path": tmp.path().to_string_lossy() }), None).unwrap()).is_err());
        assert!(execute(parse_request(&json!({ "mode": "hash", "path": tmp.path().join("missing.png").to_string_lossy() }), None).unwrap()).is_err());
    }

    #[test]
    fn thumb_alpha_exif_webp_and_cache_parity() {
        let tmp = TempDir::new("parity");

        // 1. Opaque noisy PNG (> 24 KiB) -> resized JPEG + thumbhash
        let noisy = make_noisy_rgb_png(1200, 900);
        assert!(noisy.len() as u64 > SMALL);
        let ans = execute(parse_request(&json!({ "mode": "thumb", "thumbhash": true }), Some(noisy.clone())).unwrap()).unwrap();
        assert_eq!(ans.json["skipped"], false);
        assert_eq!(ans.json["mime"], "image/jpeg");
        assert_eq!(ans.json["originalWidth"], 1200);
        assert_eq!(ans.json["originalHeight"], 900);
        assert_eq!(ans.json["width"], 720);
        assert_eq!(ans.json["height"], 540);
        assert!(ans.json["thumbhash"].as_str().is_some_and(|s| !s.is_empty()));
        let jpg_bytes = ans.bytes.expect("thumb returns bytes when dir is omitted");
        assert_eq!(jpg_bytes.len() as u64, ans.json["size"].as_u64().unwrap());
        assert!(jpg_bytes.len() < noisy.len());
        let decoded_thumb = decode_image(&jpg_bytes).unwrap();
        assert_eq!((decoded_thumb.width(), decoded_thumb.height()), (720, 540));

        // 2. Transparent RGBA PNG -> stays image/png with alpha preserved
        let transparent = make_alpha_png(1000, 800, true);
        let ans = execute(parse_request(&json!({ "mode": "custom", "maxWidth": 400, "maxHeight": 400 }), Some(transparent)).unwrap()).unwrap();
        assert_eq!(ans.json["mime"], "image/png");
        let out_png = decode_image(&ans.bytes.unwrap()).unwrap();
        assert!(out_png.color().has_alpha());
        assert!(out_png.to_rgba8().pixels().any(|p| p.0[3] < 255));

        // 3. Fully opaque RGBA PNG -> encoded as image/jpeg (matches thumbs.rs alpha check)
        let opaque_rgba = make_alpha_png(1000, 800, false);
        let ans = execute(parse_request(&json!({ "mode": "custom", "maxWidth": 400, "maxHeight": 400 }), Some(opaque_rgba)).unwrap()).unwrap();
        assert_eq!(ans.json["mime"], "image/jpeg");

        // 4. EXIF Orientation 6 (90 deg CW): stored 1200x800 -> seen as 800x1200
        let exif_jpg = make_jpeg_with_exif_orientation(1200, 800, 6);
        let hash_ans = execute(parse_request(&json!({ "mode": "hash" }), Some(exif_jpg.clone())).unwrap()).unwrap();
        assert_eq!(hash_ans.json["width"], 800);
        assert_eq!(hash_ans.json["height"], 1200);
        assert!(hash_ans.bytes.is_none());
        let box_ans = execute(parse_request(&json!({ "mode": "box", "smallBytes": 0, "ratio": 0 }), Some(exif_jpg)).unwrap()).unwrap();
        assert_eq!(box_ans.json["originalWidth"], 800);
        assert_eq!(box_ans.json["originalHeight"], 1200);
        assert_eq!(box_ans.json["width"], 400);
        assert_eq!(box_ans.json["height"], 600);

        // 5. Extreme tall image (400x4000): thumb preserves minShort=320, box fits 720x600 strictly
        let tall = make_noisy_rgb_png(400, 4000);
        let thumb_tall = execute(parse_request(&json!({ "mode": "thumb", "smallBytes": 0, "ratio": 0 }), Some(tall.clone())).unwrap()).unwrap();
        assert_eq!(thumb_tall.json["width"], 320);
        assert_eq!(thumb_tall.json["height"], 3200);
        let box_tall = execute(parse_request(&json!({ "mode": "box", "smallBytes": 0, "ratio": 0 }), Some(tall)).unwrap()).unwrap();
        assert_eq!(box_tall.json["width"], 60);
        assert_eq!(box_tall.json["height"], 600);

        // 6. Preview lossless WebP wins over JPEG on flat screenshot-like image, and decodes back as WebP
        let flat = make_flat_screenshot_png(1600, 1200);
        let prev = execute(parse_request(&json!({ "mode": "preview", "smallBytes": 0, "ratio": 0 }), Some(flat)).unwrap()).unwrap();
        assert_eq!(prev.json["mime"], "image/webp");
        let webp_bytes = prev.bytes.unwrap();
        // Also verify WebP input decodes cleanly
        let from_webp = execute(parse_request(&json!({ "mode": "hash" }), Some(webp_bytes)).unwrap()).unwrap();
        assert_eq!(from_webp.json["width"], 1600);
        assert_eq!(from_webp.json["height"], 1200);

        // 7. Small image skip
        let tiny = make_noisy_rgb_png(32, 32);
        assert!(tiny.len() as u64 <= SMALL);
        let skipped = execute(parse_request(&json!({ "mode": "thumb" }), Some(tiny)).unwrap()).unwrap();
        assert_eq!(skipped.json["skipped"], true);
        assert_eq!(skipped.json["reason"], "small");
        assert!(skipped.bytes.is_none());

        // 8. Disk cache (`dir`) write + cache hit + atomic cleanup
        let img_path = tmp.path().join("photo.png");
        let cache_dir = tmp.path().join("thumbs");
        std::fs::write(&img_path, &noisy).unwrap();
        let first = execute(
            parse_request(
                &json!({ "mode": "thumb", "path": img_path.to_string_lossy(), "dir": cache_dir.to_string_lossy() }),
                None,
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(first.json["skipped"], false);
        assert_eq!(first.json["cached"], false);
        assert_eq!(first.json["mime"], "image/jpeg");
        assert!(first.bytes.is_none());
        let cached_path = PathBuf::from(first.json["path"].as_str().unwrap());
        assert!(cached_path.is_file());
        assert_eq!(std::fs::read(&cached_path).unwrap(), jpg_bytes);
        // No leftover .part files
        let entries: Vec<_> = std::fs::read_dir(&cache_dir).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(entries.len(), 1);

        let second = execute(
            parse_request(
                &json!({ "mode": "thumb", "path": img_path.to_string_lossy(), "dir": cache_dir.to_string_lossy() }),
                None,
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(second.json["cached"], true);
        assert_eq!(second.json["path"], first.json["path"]);
        assert_eq!(second.json["mime"], "image/jpeg");
    }

    /// Byte-for-byte parity check against `station/native/mesh/src/thumbs.rs` on a real repository PNG.
    #[test]
    fn parity_with_mesh_thumbs_on_real_repo_icon() {
        let icon = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../station/native/helper/icon.png");
        if !icon.is_file() {
            return;
        }
        let icon_str = icon.to_string_lossy().into_owned();

        let hashed = execute(parse_request(&json!({ "mode": "hash", "path": &icon_str }), None).unwrap()).unwrap();
        assert_eq!(hashed.json["thumbhash"], "ygeCBQApV0d2d3C9+JhwdApXCCiHeHB4KA==");
        assert_eq!(hashed.json["width"], 1024);
        assert_eq!(hashed.json["height"], 1024);

        let thumb = execute(parse_request(&json!({ "mode": "thumb", "path": &icon_str }), None).unwrap()).unwrap();
        assert_eq!(thumb.json["skipped"], false);
        assert_eq!(thumb.json["mime"], "image/png");
        let thumb_bytes = thumb.bytes.expect("thumb bytes");
        assert_eq!(thumb_bytes.len(), 30_097);
        assert_eq!(hex::encode(Sha256::digest(&thumb_bytes)), "fb4307432ebee91179257df4c50e1daa6f43677ecfec4bc95648f48c6cae8600");

        let boxed = execute(parse_request(&json!({ "mode": "box", "path": &icon_str }), None).unwrap()).unwrap();
        assert_eq!(boxed.json["skipped"], false);
        assert_eq!(boxed.json["mime"], "image/png");
        let box_bytes = boxed.bytes.expect("box bytes");
        assert_eq!(box_bytes.len(), 30_097);
        assert_eq!(hex::encode(Sha256::digest(&box_bytes)), "fb4307432ebee91179257df4c50e1daa6f43677ecfec4bc95648f48c6cae8600");

        let prev = execute(parse_request(&json!({ "mode": "preview", "path": &icon_str }), None).unwrap()).unwrap();
        assert_eq!(prev.json["skipped"], true);
        assert_eq!(prev.json["reason"], "small");
    }
}

