//! Image thumbnail, preview, and ThumbHash generation (`image.thumb`), extracted from
//! `station/native/mesh/src/thumbs.rs` (zero N-API) for `stillfail-shell` station builds
//! (`--features station`, enabled on `shell-station` and macOS `shell-apple-station`; client apps
//! build without this feature).
//!
//! ## Contract mapping vs `station/native/mesh/src/thumbs.rs`
//! - **Inputs**: either file `path` or raw `bytes` (mutually exclusive, capped at 64 MiB).
//!   - Path inputs in `thumb` / `box` / `preview` apply case-insensitive extension filtering
//!     (`.png`, `.jpg`, `.jpeg`, `.webp`), matching `thumbs.rs::wanted`; non-matching extensions
//!     return `{ skipped: true, reason: "unsupported_extension" }`.
//!   - `hash`, `custom`, and raw `bytes` inputs detect format by magic bytes (PNG / JPEG / WebP).
//! - **Decoding & limits**: EXIF orientation, CatmullRom resampling, alpha-aware PNG / JPEG /
//!   lossless-WebP encoding, and 100px base64 ThumbHash match `thumbs.rs` byte-for-byte.
//!   Decoder limits align with `image::Limits::default()` (512 MiB) and `mesh.node` photo sizes
//!   (up to 65535 per side, 128 MP), with explicit pre-decode `decoder.total_bytes()` checks
//!   (doubled when EXIF orientation transforms require a copy) and WebP RIFF metadata bounds.
//! - **Fault tolerance**:
//!   - In `preview` mode, optional lossless WebP encoding failure falls back to the JPEG/PNG
//!     candidate (matching `thumbs.rs`).
//!   - When `dir` and `thumbhash: true` are both set, a disk cache write failure preserves and
//!     returns the already-computed `thumbhash`, `originalWidth`, and `originalHeight` alongside
//!     `skipped: true, reason: "write_failed", writeError` instead of discarding the hash.
//!   - All CPU/IO work runs inside `tokio::task::spawn_blocking` under a bounded concurrency
//!     semaphore (`MAX_CONCURRENT_JOBS`).

use std::io::{Cursor, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;

use crate::{Answer, Done, err};

/// Maximum accepted input size in bytes (64 MiB).
pub(crate) const MAX_INPUT_BYTES: u64 = 64 * 1024 * 1024;
/// Maximum accepted decoded image width or height (`u16::MAX` = 65535, matching `mesh.node`).
pub(crate) const MAX_DECODE_DIM: u32 = u16::MAX as u32;
/// Maximum accepted decoded pixel count (128 MP; covers 33–50 MP phone/panorama photos while rejecting bombs).
pub(crate) const MAX_DECODE_PIXELS: u64 = 128 * 1024 * 1024;
/// Maximum decoded buffer allocation (768 MiB: accommodates 108 MP portrait photos with 90°/270°
/// EXIF copy = 648 MiB while still rejecting 128 MP RGBA16 = 1 GiB and decompression bombs).
pub(crate) const MAX_DECODE_ALLOC: u64 = 768 * 1024 * 1024;
/// Maximum size of a single WebP metadata chunk (`EXIF` / `ICCP` / `XMP `) before decoding (8 MiB).
const MAX_WEBP_METADATA_CHUNK: usize = 8 * 1024 * 1024;
/// Maximum combined size of all WebP metadata chunks before decoding (16 MiB).
const MAX_WEBP_METADATA_TOTAL: usize = 16 * 1024 * 1024;
/// Exclusive filename prefix for temporary `.part` files owned by this module.
const PART_PREFIX: &str = ".stillfail-thumb-";
/// Maximum requested output width, height, minShort, or maxLong (matches `thumbs.rs` `max_long`).
pub(crate) const MAX_TARGET_DIM: u32 = 8192;
/// Maximum size-savings ratio multiplier (`out.len() * ratio < input_len`).
pub(crate) const MAX_RATIO: u64 = 16;
/// Maximum concurrent image decode/encode jobs to bound peak station memory under burst load.
const MAX_CONCURRENT_JOBS: usize = 4;
/// Age after which stale `.part` files in `dir` are opportunistically cleaned up (1 hour).
const STALE_PART_AGE: Duration = Duration::from_secs(3600);

/// Default JPEG quality (matches `thumbs.rs` `jpeg`: high enough that small text keeps its edges).
const DEFAULT_QUALITY: u8 = 88;
/// Chat thumbnail constants (matches `thumbs.rs`).
const MAX_W: u32 = 720;
const MAX_H: u32 = 600;
const SMALL: u64 = 24 * 1024;
const PREVIEW_MAX: u32 = 2048;
const PREVIEW_SMALL: u64 = 300 * 1024;

static PART_SEQ: AtomicU64 = AtomicU64::new(1);
static DECODE_PERMITS: LazyLock<Semaphore> = LazyLock::new(|| Semaphore::new(MAX_CONCURRENT_JOBS));

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

/// Case-insensitive image extension filter matching `station/native/mesh/src/thumbs.rs::wanted`.
fn wanted_extension(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    let lower = name.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".webp"].iter().any(|e| lower.ends_with(e))
}

fn id_of_path(path: &Path) -> String {
    hex::encode(&Sha256::digest(path.to_string_lossy().as_bytes())[..16])
}

/// Looks up an existing cached thumbnail in `dir`, rejecting symlinks via `symlink_metadata`.
fn kept(dir: &Path, id: &str, suffix: &str) -> Option<(PathBuf, &'static str)> {
    [("jpg", "image/jpeg"), ("png", "image/png"), ("webp", "image/webp")]
        .into_iter()
        .map(|(ext, kind)| (dir.join(format!("{id}{suffix}.{ext}")), kind))
        .find(|(path, _)| std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file()))
}

/// Opens `path` without blocking on FIFOs (`O_NONBLOCK` on Unix) and validates it is a regular,
/// non-empty file within `MAX_INPUT_BYTES` via the open file descriptor (eliminating stat-open TOCTOU).
fn open_regular_file(path: &Path) -> Result<(std::fs::File, u64), String> {
    let mut opts = std::fs::OpenOptions::new();
    opts.read(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::custom_flags(&mut opts, libc::O_NONBLOCK);
    let file = opts.open(path).map_err(|e| format!("cannot open input: {e}"))?;
    let meta = file.metadata().map_err(|e| format!("cannot stat open input: {e}"))?;
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
    Ok((file, len))
}

fn read_open_file(file: std::fs::File, hint_len: u64) -> Result<(Vec<u8>, u64), String> {
    let mut buf = Vec::with_capacity(hint_len.min(MAX_INPUT_BYTES) as usize);
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

/// Pre-validates WebP RIFF container chunks and returns the strictly bounded `&raw[..riff_end]`
/// slice so `image-webp` decodes the exact validated window with zero unvalidated trailing bytes.
fn validate_webp_container(raw: &[u8]) -> Result<&[u8], String> {
    if raw.len() < 12 || &raw[0..4] != b"RIFF" || &raw[8..12] != b"WEBP" {
        return Err("invalid webp RIFF header".into());
    }
    let riff_size = u32::from_le_bytes([raw[4], raw[5], raw[6], raw[7]]) as usize;
    if riff_size < 4 {
        return Err("webp RIFF size too small".into());
    }
    let riff_end = riff_size.checked_add(8).ok_or_else(|| "webp RIFF size overflow".to_string())?;
    if riff_end > raw.len() {
        return Err("webp RIFF size exceeds input length".into());
    }
    let mut pos = 12usize;
    let mut meta_total = 0usize;
    while pos < riff_end {
        if pos + 8 > riff_end {
            return Err("truncated webp chunk header".into());
        }
        let fourcc = &raw[pos..pos + 4];
        let chunk_size = u32::from_le_bytes([raw[pos + 4], raw[pos + 5], raw[pos + 6], raw[pos + 7]]) as usize;
        let data_start = pos + 8;
        let data_end = data_start.checked_add(chunk_size).ok_or_else(|| "webp chunk size overflow".to_string())?;
        if data_end > riff_end {
            return Err("webp chunk exceeds RIFF container".into());
        }
        let padded_end = data_end.checked_add(chunk_size & 1).ok_or_else(|| "webp chunk padding overflow".to_string())?;
        if padded_end > riff_end {
            return Err("webp chunk padding exceeds RIFF container".into());
        }
        if matches!(fourcc, b"EXIF" | b"ICCP" | b"XMP ") {
            if chunk_size > MAX_WEBP_METADATA_CHUNK {
                return Err(format!("webp metadata chunk exceeds limit {MAX_WEBP_METADATA_CHUNK}"));
            }
            meta_total = meta_total.saturating_add(chunk_size);
            if meta_total > MAX_WEBP_METADATA_TOTAL {
                return Err(format!("webp metadata total exceeds limit {MAX_WEBP_METADATA_TOTAL}"));
            }
        }
        pos = padded_end;
    }
    Ok(&raw[..riff_end])
}

/// EXIF orientations 5–8 (90°/270° rotations and transposed flips) allocate a second image buffer
/// in `DynamicImage::apply_orientation`; orientations 1–4 (`NoTransforms`, flips, 180°) are in-place.
fn orientation_allocates_copy(o: Orientation) -> bool {
    matches!(
        o,
        Orientation::Rotate90
            | Orientation::Rotate270
            | Orientation::Rotate90FlipH
            | Orientation::Rotate270FlipH
    )
}

fn check_decode_budget(total_bytes: u64, orientation: Option<Orientation>) -> Result<(), String> {
    if total_bytes == 0 {
        return Err("image has zero decoded byte size".into());
    }
    if total_bytes > MAX_DECODE_ALLOC {
        return Err(format!("decoded image buffer {total_bytes} bytes exceeds limit {MAX_DECODE_ALLOC}"));
    }
    if orientation.is_some_and(orientation_allocates_copy) && total_bytes.saturating_mul(2) > MAX_DECODE_ALLOC {
        return Err(format!(
            "decoded image buffer with orientation transform ({} bytes) exceeds limit {MAX_DECODE_ALLOC}",
            total_bytes.saturating_mul(2)
        ));
    }
    Ok(())
}

fn decode_image(raw: &[u8]) -> Result<DynamicImage, String> {
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_DECODE_DIM);
    limits.max_image_height = Some(MAX_DECODE_DIM);
    limits.max_alloc = Some(MAX_DECODE_ALLOC);

    let probed = ImageReader::new(Cursor::new(raw))
        .with_guessed_format()
        .map_err(|e| format!("cannot detect image format: {e}"))?;
    let format = probed.format().ok_or_else(|| "unsupported or unknown image format".to_string())?;
    if !matches!(format, ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::WebP) {
        return Err(format!("unsupported image format: {format:?}"));
    }

    let mut reader = if format == ImageFormat::WebP {
        let validated = validate_webp_container(raw)?;
        ImageReader::with_format(Cursor::new(validated), ImageFormat::WebP)
    } else {
        probed
    };
    reader.limits(limits);

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

    // Explicit pre-decode memory check by actual color depth: `into_decoder -> from_decoder` does
    // not automatically reserve `decoder.total_bytes()` against `Limits::max_alloc`.
    let total_bytes = decoder.total_bytes();
    let orientation = decoder.orientation().ok();
    check_decode_budget(total_bytes, orientation)?;

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

/// Strictly matches only temporary `.part` filenames generated by `write_atomic`:
/// `.stillfail-thumb-<32 lowercase hex>[.<b|p>].<jpg|png|webp>.<pid>.<seq>.part`.
fn is_own_part_file(name: &str) -> bool {
    let Some(rest) = name.strip_prefix(PART_PREFIX).and_then(|s| s.strip_suffix(".part")) else {
        return false;
    };
    let parts: Vec<&str> = rest.split('.').collect();
    let (id, ext, pid, seq) = match parts.as_slice() {
        [id, ext, pid, seq] => (*id, *ext, *pid, *seq),
        [id, suffix, ext, pid, seq] if matches!(*suffix, "b" | "p") => (*id, *ext, *pid, *seq),
        _ => return false,
    };
    id.len() == 32
        && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        && matches!(ext, "jpg" | "png" | "webp")
        && pid.parse::<u32>().ok().is_some_and(|v| v.to_string() == pid)
        && seq.parse::<u64>().ok().is_some_and(|v| v.to_string() == seq)
}

/// Opportunistically removes only stale temp files created by this module (`PART_PREFIX` + `.part`)
/// older than `max_age` (best-effort); never touches unrelated `*.part` files in `dir`.
fn cleanup_stale_parts(dir: &Path, max_age: Duration) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.file_name().and_then(|n| n.to_str()).is_some_and(is_own_part_file) {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let Ok(modified) = meta.modified() else {
            continue;
        };
        if now.duration_since(modified).is_ok_and(|age| age >= max_age) {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// Atomically writes `bytes` to `{dir}/{id}{suffix}.{ext}` via an exclusively created (`O_EXCL`)
/// `.stillfail-thumb-*.part` file so symlinks are never followed and existing files are never clobbered.
fn write_atomic(dir: &Path, id: &str, suffix: &str, ext: &str, bytes: &[u8]) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create thumb dir: {e}"))?;
    cleanup_stale_parts(dir, STALE_PART_AGE);
    let path = dir.join(format!("{id}{suffix}.{ext}"));
    let seq = PART_SEQ.fetch_add(1, Ordering::Relaxed);
    let partial = dir.join(format!("{PART_PREFIX}{id}{suffix}.{ext}.{}.{seq}.part", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&partial)
        .map_err(|e| format!("cannot create thumb temp file: {e}"))?;
    if let Err(e) = file.write_all(bytes) {
        drop(file);
        let _ = std::fs::remove_file(&partial);
        return Err(format!("cannot write thumb: {e}"));
    }
    drop(file);
    if let Err(e) = std::fs::rename(&partial, &path) {
        let _ = std::fs::remove_file(&partial);
        return Err(format!("cannot rename thumb: {e}"));
    }
    Ok(path)
}

enum FastPath {
    Done(Answer),
    NeedDecode(Request),
}

/// Pure-memory fast paths (extension filter and small-bytes skip) that run without I/O or decode permits.
fn try_memory_fast_path(req: &Request) -> Option<Answer> {
    if let Input::Path(path) = &req.input
        && matches!(req.mode, Mode::Thumb | Mode::Box | Mode::Preview)
        && !wanted_extension(path)
    {
        return Some(Answer::json(json!({ "skipped": true, "reason": "unsupported_extension" })));
    }
    if let (Input::Bytes(b), Some(spec)) = (&req.input, &req.spec)
        && !req.thumbhash
        && spec.small_bytes > 0
        && (b.len() as u64) <= spec.small_bytes
    {
        return Some(Answer::json(json!({ "skipped": true, "reason": "small" })));
    }
    None
}

/// Cheap stat / cache-hit fast path for path inputs when `thumbhash` is not requested,
/// run before acquiring the bounded decode concurrency semaphore. Drops the opened file
/// descriptor immediately on cache miss so queued requests never hold FDs while waiting.
fn try_path_fast_path(req: Request) -> Result<FastPath, String> {
    if let (Input::Path(path), Some(spec)) = (&req.input, &req.spec)
        && !req.thumbhash
    {
        let (file, len) = open_regular_file(path)?;
        drop(file);
        if spec.small_bytes > 0 && len <= spec.small_bytes {
            return Ok(FastPath::Done(Answer::json(json!({ "skipped": true, "reason": "small" }))));
        }
        if let Some(dir) = &req.dir {
            let id = id_of_path(path);
            if let Some((found, kind)) = kept(dir, &id, spec.suffix) {
                return Ok(FastPath::Done(Answer::json(json!({
                    "skipped": false,
                    "cached": true,
                    "path": found.to_string_lossy(),
                    "mime": kind,
                }))));
            }
        }
        return Ok(FastPath::NeedDecode(req));
    }
    Ok(FastPath::NeedDecode(req))
}

fn execute_decode(req: Request) -> Done {
    let owned_raw;
    let (raw, input_len): (&[u8], u64) = match &req.input {
        Input::Path(path) => {
            let (file, hint_len) = open_regular_file(path)?;
            let (buf, len) = read_open_file(file, hint_len)?;
            owned_raw = buf;
            (&owned_raw, len)
        }
        Input::Bytes(b) => (b.as_slice(), b.len() as u64),
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
    // Optional lossless WebP candidate: fall back to JPEG/PNG if WebP encoding fails (matching `thumbs.rs`).
    if spec.lossless
        && let Ok(exact) = encode_webp(&small, clear)
        && exact.len() < encoded.len()
    {
        (ext, kind, encoded) = ("webp", "image/webp", exact);
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
    if let Some(ref h) = hash {
        out["thumbhash"] = Value::String(h.clone());
    }

    if let (Input::Path(path), Some(dir)) = (&req.input, &req.dir) {
        let id = id_of_path(path);
        match write_atomic(dir, &id, spec.suffix, ext, &encoded) {
            Ok(written) => {
                out["cached"] = Value::Bool(false);
                out["path"] = Value::String(written.to_string_lossy().into_owned());
                Ok(Answer::json(out))
            }
            Err(write_err) => {
                // When thumbhash was computed in the same call, preserve it and surface the write error.
                if let Some(h) = hash {
                    Ok(Answer::json(json!({
                        "skipped": true,
                        "reason": "write_failed",
                        "writeError": write_err,
                        "originalWidth": ow,
                        "originalHeight": oh,
                        "thumbhash": h,
                    })))
                } else {
                    Err(write_err)
                }
            }
        }
    } else {
        Ok(Answer::bytes(out, encoded))
    }
}

#[cfg(test)]
fn execute(req: Request) -> Done {
    if let Some(ans) = try_memory_fast_path(&req) {
        return Ok(ans);
    }
    match try_path_fast_path(req)? {
        FastPath::Done(ans) => Ok(ans),
        FastPath::NeedDecode(req) => execute_decode(req),
    }
}

pub(crate) async fn run(a: Value, bytes: Option<Vec<u8>>) -> Done {
    let req = parse_request(&a, bytes)?;
    // Cheap extension/small-bytes skips run immediately without acquiring decode permits.
    if let Some(ans) = try_memory_fast_path(&req) {
        return Ok(ans);
    }
    // Cheap stat/cache-hit fast path runs off the async executor without waiting behind heavy decodes.
    let req = if matches!(req.input, Input::Path(_)) && !req.thumbhash && req.spec.is_some() {
        match tokio::task::spawn_blocking(move || try_path_fast_path(req)).await.map_err(err)?? {
            FastPath::Done(ans) => return Ok(ans),
            FastPath::NeedDecode(req) => req,
        }
    } else {
        req
    };
    let _permit = DECODE_PERMITS
        .acquire()
        .await
        .map_err(|_| "image.thumb concurrency limiter closed".to_string())?;
    tokio::task::spawn_blocking(move || execute_decode(req)).await.map_err(err)?
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
            *p = if x < w / 2 && y < h / 2 {
                Rgb([240, 30, 30])
            } else if x >= w / 2 && y < h / 2 {
                Rgb([30, 240, 30])
            } else if x < w / 2 {
                Rgb([30, 30, 240])
            } else {
                Rgb([240, 240, 30])
            };
        }
        let mut raw_jpg = Vec::new();
        DynamicImage::ImageRgb8(img)
            .to_rgb8()
            .write_with_encoder(JpegEncoder::new_with_quality(&mut raw_jpg, 95))
            .unwrap();
        assert_eq!(&raw_jpg[0..2], &[0xFF, 0xD8]);

        let mut exif = Vec::new();
        exif.extend_from_slice(b"Exif\0\0");
        exif.extend_from_slice(b"II");
        exif.extend_from_slice(&42u16.to_le_bytes());
        exif.extend_from_slice(&8u32.to_le_bytes());
        exif.extend_from_slice(&1u16.to_le_bytes());
        exif.extend_from_slice(&0x0112u16.to_le_bytes());
        exif.extend_from_slice(&3u16.to_le_bytes());
        exif.extend_from_slice(&1u32.to_le_bytes());
        exif.extend_from_slice(&orientation.to_le_bytes());
        exif.extend_from_slice(&0u16.to_le_bytes());
        exif.extend_from_slice(&0u32.to_le_bytes());

        let seg_len = (exif.len() + 2) as u16;
        let mut out = Vec::with_capacity(raw_jpg.len() + exif.len() + 4);
        out.extend_from_slice(&raw_jpg[0..2]);
        out.extend_from_slice(&[0xFF, 0xE1]);
        out.extend_from_slice(&seg_len.to_be_bytes());
        out.extend_from_slice(&exif);
        out.extend_from_slice(&raw_jpg[2..]);
        out
    }

    /// Builds a minimal synthetic PNG header claiming dimensions `w x h` with given bit depth & color type.
    fn make_fake_png_header_with_color(w: u32, h: u32, bit_depth: u8, color_type: u8) -> Vec<u8> {
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
        out.extend_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]);
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(b"IHDR");
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[bit_depth, color_type, 0, 0, 0]);
        out.extend_from_slice(&13u32.to_be_bytes());
        out.extend_from_slice(&ihdr);
        out.extend_from_slice(&crc32(&ihdr).to_be_bytes());
        // Include a 1-byte IDAT chunk so `png` decoder header parsing succeeds and our dimension/total_bytes guards run.
        let idat = b"IDAT\x00";
        out.extend_from_slice(&1u32.to_be_bytes());
        out.extend_from_slice(idat);
        out.extend_from_slice(&crc32(idat).to_be_bytes());
        out.extend_from_slice(&0u32.to_be_bytes());
        out.extend_from_slice(b"IEND");
        out.extend_from_slice(&crc32(b"IEND").to_be_bytes());
        out
    }

    fn make_fake_png_header(w: u32, h: u32) -> Vec<u8> {
        make_fake_png_header_with_color(w, h, 8, 6)
    }

    #[test]
    fn rejects_invalid_parameters() {
        let png = make_noisy_rgb_png(64, 64);

        assert!(parse_request(&json!(null), Some(png.clone())).is_err());
        assert!(parse_request(&json!([]), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "max_width": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "/tmp/a.png" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "/tmp/a\0b.png" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "hash" }), Some(Vec::new())).is_err());
        assert!(parse_request(&json!({}), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "bogus" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxWidth": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "maxHeight": 100 }), Some(png.clone())).is_err());
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
        assert!(parse_request(&json!({ "mode": "hash", "maxWidth": 100 }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "thumbhash": false }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "thumb", "dir": "/tmp/t" }), Some(png.clone())).is_err());
        assert!(parse_request(&json!({ "mode": "hash", "path": "/tmp/a.png", "dir": "/tmp/t" }), None).is_err());
        assert!(parse_request(&json!({ "mode": "custom", "path": "/tmp/a.png", "dir": "/tmp/t", "maxWidth": 100, "maxHeight": 100 }), None).is_err());
        assert!(parse_request(&json!({ "mode": "thumb", "path": "/tmp/a.png", "dir": "/tmp/t", "maxWidth": 100 }), None).is_err());
    }

    #[test]
    fn rejects_decompression_bombs_depth_overflow_webp_metadata_and_corrupt_inputs() {
        // 25000 x 25000 = 625 MP > MAX_DECODE_PIXELS (128 MP)
        let bomb_pixels = make_fake_png_header(25_000, 25_000);
        let err = execute(parse_request(&json!({ "mode": "hash" }), Some(bomb_pixels)).unwrap())
            .err()
            .expect("pixel bomb must be rejected");
        assert!(err.contains("limit") || err.contains("exceed") || err.contains("decode"), "unexpected err: {err}");

        // 70000 x 10 exceeds MAX_DECODE_DIM (65535)
        let bomb_dim = make_fake_png_header(70_000, 10);
        let err = execute(parse_request(&json!({ "mode": "hash" }), Some(bomb_dim)).unwrap())
            .err()
            .expect("dim bomb must be rejected");
        assert!(err.contains("limit") || err.contains("exceed") || err.contains("decode"), "unexpected err: {err}");

        // 16384 x 8192 = 128 MP RGBA16 -> 1 GiB > MAX_DECODE_ALLOC (512 MiB), caught by decoder.total_bytes()
        let bomb_rgba16 = make_fake_png_header_with_color(16_384, 8_192, 16, 6);
        let err = execute(parse_request(&json!({ "mode": "hash" }), Some(bomb_rgba16)).unwrap())
            .err()
            .expect("1 GiB RGBA16 image must be rejected by total_bytes pre-check");
        assert!(err.contains("decoded image buffer") && err.contains("exceeds limit"), "unexpected err: {err}");

        // Oversized WebP EXIF metadata chunk (> 8 MiB) inside RIFF container rejected before image-webp decodes
        let exif_len = (MAX_WEBP_METADATA_CHUNK + 16) as u32;
        let mut big_webp = Vec::with_capacity(12 + 8 + exif_len as usize);
        big_webp.extend_from_slice(b"RIFF");
        big_webp.extend_from_slice(&(4u32 + 8 + exif_len).to_le_bytes());
        big_webp.extend_from_slice(b"WEBP");
        big_webp.extend_from_slice(b"EXIF");
        big_webp.extend_from_slice(&exif_len.to_le_bytes());
        big_webp.resize(12 + 8 + exif_len as usize, 0);
        let err = validate_webp_container(&big_webp).expect_err("oversized WebP EXIF must be rejected");
        assert!(err.contains("metadata chunk exceeds limit"), "unexpected err: {err}");

        // WebP RIFF size claiming more bytes than input length must be rejected
        let mut lying_webp = Vec::new();
        lying_webp.extend_from_slice(b"RIFF");
        lying_webp.extend_from_slice(&1000u32.to_le_bytes());
        lying_webp.extend_from_slice(b"WEBP");
        let err = validate_webp_container(&lying_webp).expect_err("lying RIFF length must be rejected");
        assert!(err.contains("exceeds input length"), "unexpected err: {err}");

        // WebP with hidden trailing huge EXIF chunk past declared RIFF end: validator returns strictly
        // `&raw[..riff_end]`, so the decoder never sees unvalidated trailing bytes.
        let flat_small = make_flat_screenshot_png(64, 64);
        let valid_webp = encode_webp(&decode_image(&flat_small).unwrap(), false).unwrap();
        let valid_len = valid_webp.len();
        let mut trailed = valid_webp.clone();
        trailed.extend_from_slice(b"EXIF");
        trailed.extend_from_slice(&exif_len.to_le_bytes());
        trailed.extend_from_slice(&[0u8; 64]);
        let sliced = validate_webp_container(&trailed).expect("valid RIFF prefix slices cleanly");
        assert_eq!(sliced.len(), valid_len);
        assert_eq!(sliced, valid_webp.as_slice());

        // EXIF 1x in-place (orientations 1-4) vs 2x copy (orientations 5-8) memory budget checks
        let mib = 1024 * 1024;
        assert!(check_decode_budget(400 * mib, Some(Orientation::Rotate180)).is_ok());
        assert!(check_decode_budget(400 * mib, Some(Orientation::FlipHorizontal)).is_ok());
        assert!(check_decode_budget(400 * mib, Some(Orientation::FlipVertical)).is_ok());
        assert!(check_decode_budget(324 * mib, Some(Orientation::Rotate90)).is_ok()); // 108 MP portrait: 648 MiB <= 768 MiB
        assert!(check_decode_budget(400 * mib, Some(Orientation::Rotate90)).is_err()); // 800 MiB > 768 MiB
        assert!(check_decode_budget(400 * mib, Some(Orientation::Rotate270)).is_err());
        assert!(check_decode_budget(1024 * mib, None).is_err()); // 1 GiB > 768 MiB

        // Orientation 3 (180 deg) JPEG decodes in-place preserving 1200x800 dimensions
        let exif3_jpg = make_jpeg_with_exif_orientation(1200, 800, 3);
        let h3 = execute(parse_request(&json!({ "mode": "hash" }), Some(exif3_jpg)).unwrap()).unwrap();
        assert_eq!(h3.json["width"], 1200);
        assert_eq!(h3.json["height"], 800);

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
    fn accepts_48mp_photo_and_filters_path_extensions() {
        let tmp = TempDir::new("ext-and-48mp");

        // Path extension filtering (case-insensitive) for thumb / box / preview; hash & bytes inspect content.
        let png = make_noisy_rgb_png(800, 600);
        for bad_name in ["anim.gif", "blob.data", "noext", "doc.pdf"] {
            let p = tmp.path().join(bad_name);
            std::fs::write(&p, &png).unwrap();
            for mode in ["thumb", "box", "preview"] {
                let ans = execute(parse_request(&json!({ "mode": mode, "path": p.to_string_lossy() }), None).unwrap()).unwrap();
                assert_eq!(ans.json["skipped"], true, "{bad_name} in {mode}");
                assert_eq!(ans.json["reason"], "unsupported_extension", "{bad_name} in {mode}");
                assert!(ans.bytes.is_none());
            }
            // `hash` mode still decodes by content regardless of extension.
            let h = execute(parse_request(&json!({ "mode": "hash", "path": p.to_string_lossy() }), None).unwrap()).unwrap();
            assert_eq!(h.json["width"], 800);
            assert_eq!(h.json["height"], 600);
        }
        // Uppercase `.PNG` is accepted.
        let upper = tmp.path().join("UPPER.PNG");
        std::fs::write(&upper, &png).unwrap();
        let ans = execute(parse_request(&json!({ "mode": "thumb", "path": upper.to_string_lossy() }), None).unwrap()).unwrap();
        assert_eq!(ans.json["skipped"], false);
        assert_eq!(ans.json["mime"], "image/jpeg");

        // 8064x6048 (48.8 MP) solid-color PNG matches `mesh.node` ThumbHash & JPEG bytes with 0 drift.
        let big = ImageBuffer::<Rgb<u8>, Vec<u8>>::from_pixel(8064, 6048, Rgb([42, 128, 200]));
        let mut big_png = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(big).write_to(&mut big_png, ImageFormat::Png).unwrap();
        let big_bytes = big_png.into_inner();
        let ans = execute(parse_request(&json!({ "mode": "thumb", "thumbhash": true }), Some(big_bytes)).unwrap()).unwrap();
        assert_eq!(ans.json["skipped"], false);
        assert_eq!(ans.json["mime"], "image/jpeg");
        assert_eq!(ans.json["originalWidth"], 8064);
        assert_eq!(ans.json["originalHeight"], 6048);
        assert_eq!(ans.json["thumbhash"], "XlQBBYCHh4d4eIeAh3iHdXh4gIf4");
        let thumb_bytes = ans.bytes.expect("48.8 MP thumb bytes");
        assert_eq!(thumb_bytes.len(), 11_339);
        assert_eq!(hex::encode(Sha256::digest(&thumb_bytes)), "062e82f354f2d264c0d51f555027ca119edc2118bec7abcfd25f6d478a133ee4");
    }

    #[test]
    fn thumb_write_failure_preserves_thumbhash_and_anti_symlink_and_stale_part_cleanup() {
        let tmp = TempDir::new("cache-safety");
        let noisy = make_noisy_rgb_png(1200, 900);
        let img_path = tmp.path().join("sample.png");
        std::fs::write(&img_path, &noisy).unwrap();

        // 1. Unwritable dir (regular file blocking create_dir_all): with thumbhash=true, hash/dims are preserved.
        let blocker = tmp.path().join("not-a-dir");
        std::fs::write(&blocker, b"file").unwrap();
        let ans = execute(
            parse_request(
                &json!({ "mode": "thumb", "path": img_path.to_string_lossy(), "dir": blocker.to_string_lossy(), "thumbhash": true }),
                None,
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(ans.json["skipped"], true);
        assert_eq!(ans.json["reason"], "write_failed");
        assert!(ans.json["writeError"].as_str().is_some_and(|s| !s.is_empty()));
        assert_eq!(ans.json["originalWidth"], 1200);
        assert_eq!(ans.json["originalHeight"], 900);
        assert!(ans.json["thumbhash"].as_str().is_some_and(|s| !s.is_empty()));

        // Without thumbhash=true, the same unwritable dir returns an explicit Err.
        let err = execute(
            parse_request(
                &json!({ "mode": "thumb", "path": img_path.to_string_lossy(), "dir": blocker.to_string_lossy() }),
                None,
            )
            .unwrap(),
        );
        assert!(err.is_err());

        // 2. Anti-symlink cache lookup: a symlink at `{id}.jpg` is NOT treated as a valid cache hit.
        #[cfg(unix)]
        {
            let cache_dir = tmp.path().join("sym-cache");
            std::fs::create_dir_all(&cache_dir).unwrap();
            let id = id_of_path(&img_path);
            let decoy = tmp.path().join("decoy.jpg");
            std::fs::write(&decoy, b"not-a-cached-thumb").unwrap();
            let link_path = cache_dir.join(format!("{id}.jpg"));
            std::os::unix::fs::symlink(&decoy, &link_path).unwrap();
            assert!(kept(&cache_dir, &id, "").is_none(), "symlink must not match kept()");
        }

        // 3. Stale `.part` cleanup removes ONLY strictly formatted `.stillfail-thumb-<32hex>[.<b|p>].<ext>.<pid>.<seq>.part`
        // files and NEVER touches unrelated `*.part` or malformed same-prefix files.
        let stale_dir = tmp.path().join("stale");
        std::fs::create_dir_all(&stale_dir).unwrap();
        let own_part = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.jpg.1.1.part"));
        let own_box_part = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.b.png.42.7.part"));
        let own_prev_part = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.p.webp.42.8.part"));
        let custom_prefix_part = stale_dir.join(format!("{PART_PREFIX}custom.part"));
        let bad_ext_part = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.gif.1.1.part"));
        let leading_zero_pid = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.jpg.0123.1.part"));
        let leading_zero_seq = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.jpg.123.01.part"));
        let overflow_pid = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.jpg.4294967296.1.part"));
        let overflow_seq = stale_dir.join(format!("{PART_PREFIX}0123456789abcdef0123456789abcdef.jpg.123.18446744073709551616.part"));
        let other_part = stale_dir.join("other.part");
        let real_file = stale_dir.join("keep.jpg");
        for p in [
            &own_part,
            &own_box_part,
            &own_prev_part,
            &custom_prefix_part,
            &bad_ext_part,
            &leading_zero_pid,
            &leading_zero_seq,
            &overflow_pid,
            &overflow_seq,
            &other_part,
            &real_file,
        ] {
            std::fs::write(p, b"data").unwrap();
        }
        cleanup_stale_parts(&stale_dir, Duration::ZERO);
        assert!(!own_part.exists(), "stale own thumb .part must be removed");
        assert!(!own_box_part.exists(), "stale own box .part must be removed");
        assert!(!own_prev_part.exists(), "stale own preview .part must be removed");
        assert!(custom_prefix_part.exists(), "same-prefix non-matching .part must NEVER be deleted");
        assert!(bad_ext_part.exists(), "unknown-ext .part must NEVER be deleted");
        assert!(leading_zero_pid.exists(), "leading-zero PID .part must NEVER be deleted");
        assert!(leading_zero_seq.exists(), "leading-zero seq .part must NEVER be deleted");
        assert!(overflow_pid.exists(), "u32-overflow PID .part must NEVER be deleted");
        assert!(overflow_seq.exists(), "u64-overflow seq .part must NEVER be deleted");
        assert!(other_part.exists(), "unrelated other.part must NEVER be deleted");
        assert!(real_file.exists(), "non-.part file must be kept");
    }

    #[cfg(unix)]
    #[test]
    fn fifo_path_is_rejected_without_blocking() {
        let tmp = TempDir::new("fifo");
        let fifo = tmp.path().join("pipe.png");
        let c_path = std::ffi::CString::new(fifo.to_string_lossy().as_bytes()).unwrap();
        let rc = unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) };
        assert_eq!(rc, 0, "mkfifo failed");
        let err = open_regular_file(&fifo).expect_err("FIFO must be rejected immediately");
        assert!(err.contains("regular file"), "unexpected err: {err}");
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
