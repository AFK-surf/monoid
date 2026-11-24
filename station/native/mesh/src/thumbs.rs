//! Thumbnails and ThumbHashes of the images sent in chats, for the station in TypeScript (src/drive/thumbs.ts),
//! decoding and encoding off Node's thread using the `image` and `thumbhash` crates. Which files, when,
//! and what is kept with a message: the TypeScript's.

use std::io::Cursor;
use std::path::{Path, PathBuf};

use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader};
use napi_derive::napi;
use sha2::{Digest, Sha256};

/// The largest a chat shows an image (its box is at most 360×300), at twice that for sharp screens.
const MAX_W: u32 = 720;
const MAX_H: u32 = 600;
/// An image already this small is shown itself.
const SMALL: u64 = 24 * 1024;

/// What the whole-window viewer shows before the image itself (`preview`): as large as a screen shows it whole, at most
/// this across either way; the image itself only to zoom in, save or share.
const PREVIEW_MAX: u32 = 2048;
/// An image this small is read whole there at once.
const PREVIEW_SMALL: u64 = 300 * 1024;

/// A smaller copy of an image: how large at most, which name beside its id, how much smaller it must come out to be
/// kept (bytes × `of` below the image's), and whether a lossless WebP is tried too (kept where it is the smaller).
/// When `min_short > 0`, extreme tall/wide images keep their short side at least `min_short` (without upscaling) up to
/// `max_long` on the long side so FitCover thumbnails stay legible.
struct Size {
    max_w: u32,
    max_h: u32,
    min_short: u32,
    max_long: u32,
    suffix: &'static str,
    of: u64,
    lossless: bool,
}
const THUMB: Size = Size { max_w: MAX_W, max_h: MAX_H, min_short: 320, max_long: 8192, suffix: "", of: 1, lossless: false };
/// Strictly bounded 720×600 thumbnail without short-side floor (for inline-sized link previews).
const BOX_THUMB: Size = Size { max_w: MAX_W, max_h: MAX_H, min_short: 0, max_long: 0, suffix: ".b", of: 1, lossless: false };
/// Kept only at half the image or less: anything more saves too little of the wait to be worth a second read. A
/// screenshot of text is often smaller as a lossless WebP than as a JPEG, and then has every edge as it was; a photo
/// is the JPEG. (Not a lossy WebP: the `image` crate writes none, and the app's own decoder reads only lossless ones.)
const PREVIEW: Size = Size { max_w: PREVIEW_MAX, max_h: PREVIEW_MAX, min_short: 0, max_long: 0, suffix: ".p", of: 2, lossless: true };

/// Whether a file is an image a thumbnail is made for (a GIF would lose its motion).
fn wanted(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".webp"].iter().any(|e| lower.ends_with(e))
}

/// thumbs.rs `thumbnail`. When `boxed` is true, fits strictly within MAX_W×MAX_H (`BOX_THUMB`).
fn thumbnail_of(image: &Path, dir: &Path, boxed: bool) -> Option<(PathBuf, &'static str)> {
    let name = image.file_name()?.to_str()?;
    if !wanted(name) {
        return None;
    }
    let len = std::fs::metadata(image).ok()?.len();
    if len <= SMALL {
        return None;
    }
    let id = id_of(image);
    let size = if boxed { &BOX_THUMB } else { &THUMB };
    kept(dir, &id, size).or_else(|| make(decode(image)?, len, dir, &id, size))
}

/// thumbs.rs `preview`: as `thumbnail`, at PREVIEW, for an image over PREVIEW_SMALL.
fn preview_of(image: &Path, dir: &Path) -> Option<(PathBuf, &'static str)> {
    let name = image.file_name()?.to_str()?;
    if !wanted(name) {
        return None;
    }
    let len = std::fs::metadata(image).ok()?.len();
    if len <= PREVIEW_SMALL {
        return None;
    }
    let id = id_of(image);
    kept(dir, &id, &PREVIEW).or_else(|| make(decode(image)?, len, dir, &id, &PREVIEW))
}

fn id_of(image: &Path) -> String {
    hex::encode(&Sha256::digest(image.to_string_lossy().as_bytes())[..16])
}

fn kept(dir: &Path, id: &str, size: &Size) -> Option<(PathBuf, &'static str)> {
    let suffix = size.suffix;
    [("jpg", "image/jpeg"), ("png", "image/png"), ("webp", "image/webp")].into_iter().map(|(ext, kind)| (dir.join(format!("{id}{suffix}.{ext}")), kind)).find(|(path, _)| path.is_file())
}

/// The image as it is seen: turned as its camera says (a photo's EXIF), which a copy without that note must do itself.
fn decode(image: &Path) -> Option<DynamicImage> {
    let mut decoder = ImageReader::open(image).ok()?.with_guessed_format().ok()?.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut decoded = DynamicImage::from_decoder(decoder).ok()?;
    if let Some(orientation) = orientation {
        decoded.apply_orientation(orientation);
    }
    Some(decoded)
}

fn make(decoded: DynamicImage, len: u64, dir: &Path, id: &str, size: &Size) -> Option<(PathBuf, &'static str)> {
    // Resampled with care: most are screenshots of text, which a quick filter leaves jagged. Never made larger.
    let (max_w, max_h) = (size.max_w, size.max_h);
    let (ow, oh) = (decoded.width(), decoded.height());
    let small = if ow <= max_w && oh <= max_h {
        decoded
    } else {
        let fit_k = (max_w as f64 / ow as f64).min(max_h as f64 / oh as f64);
        let short = ow.min(oh) as f64;
        let long = ow.max(oh) as f64;
        if size.min_short > 0 && short * fit_k < size.min_short as f64 {
            let short_k = (size.min_short as f64 / short).min(1.0);
            let long_cap_k = if size.max_long > 0 { (size.max_long as f64 / long).min(1.0) } else { 1.0 };
            let k = fit_k.max(short_k.min(long_cap_k));
            if k < 1.0 {
                let nw = (ow as f64 * k).round().max(1.0) as u32;
                let nh = (oh as f64 * k).round().max(1.0) as u32;
                decoded.resize_exact(nw, nh, FilterType::CatmullRom)
            } else {
                decoded
            }
        } else {
            decoded.resize(max_w, max_h, FilterType::CatmullRom)
        }
    };
    // Clear parts stay clear (PNG); anything else is a photo or a screenshot, smallest as JPEG.
    let clear = small.color().has_alpha() && small.to_rgba8().pixels().any(|p| p.0[3] < 255);
    let (mut ext, mut kind, mut bytes) = if clear { ("png", "image/png", png(&small)?) } else { ("jpg", "image/jpeg", jpeg(&small)?) };
    if size.lossless
        && let Some(exact) = webp(&small, clear).filter(|exact| exact.len() < bytes.len())
    {
        (ext, kind, bytes) = ("webp", "image/webp", exact);
    }
    // No smaller than the image itself (a preview: than half of it): it is shown as it is.
    if bytes.len() as u64 * size.of >= len {
        return None;
    }
    std::fs::create_dir_all(dir).ok()?;
    let suffix = size.suffix;
    let path = dir.join(format!("{id}{suffix}.{ext}"));
    // Written whole before it is there to be read.
    let partial = dir.join(format!("{id}{suffix}.{ext}.part"));
    std::fs::write(&partial, bytes).ok()?;
    std::fs::rename(&partial, &path).ok()?;
    Some((path, kind))
}

fn png(image: &DynamicImage) -> Option<Vec<u8>> {
    let mut out = Cursor::new(Vec::new());
    image.write_to(&mut out, ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// Lossless: every pixel as it is (with its clear parts when it has them).
fn webp(image: &DynamicImage, clear: bool) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let encoder = image::codecs::webp::WebPEncoder::new_lossless(&mut out);
    if clear { image.to_rgba8().write_with_encoder(encoder).ok()? } else { image.to_rgb8().write_with_encoder(encoder).ok()? }
    Some(out)
}

/// Quality high enough that small text keeps its edges.
fn jpeg(image: &DynamicImage) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    image.to_rgb8().write_with_encoder(JpegEncoder::new_with_quality(&mut out, 88)).ok()?;
    Some(out)
}

/// The image's ThumbHash (base64), taken from it at most 100px across, as the format wants.
fn hash(image: &DynamicImage) -> String {
    let small = image.thumbnail(100, 100).to_rgba8();
    let bytes = thumbhash::rgba_to_thumb_hash(small.width() as usize, small.height() as usize, small.as_raw());
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[napi(object)]
pub struct Thumbnail {
    pub path: String,
    /// Its content type: image/jpeg, or image/png for one with clear parts (a preview: image/webp where that is smaller).
    #[napi(js_name = "type")]
    pub kind: String,
}

/// thumbs.rs `thumbnail`: the image's thumbnail in `dir` and its type, made if it is not there yet; null when the image
/// is shown itself (not a png/jpg/jpeg/webp by its name, 24 KiB or less, not readable as an image, or no smaller made).
#[napi]
pub async fn thumbnail(image: String, dir: String, boxed: Option<bool>) -> Option<Thumbnail> {
    let boxed = boxed.unwrap_or(false);
    let found = tokio::task::spawn_blocking(move || thumbnail_of(Path::new(&image), Path::new(&dir), boxed)).await.ok().flatten()?;
    Some(Thumbnail { path: found.0.to_string_lossy().into_owned(), kind: found.1.to_string() })
}

/// thumbs.rs `preview`: the image's preview in `dir` (`<id>.p.jpg`, `.p.png` with clear parts, or a lossless `.p.webp`
/// where that is smaller) and its type, made if it is not there yet: at most 2048 across either way, never made larger;
/// null when the image itself is shown (not a png/jpg/jpeg/webp by its name, 300 KiB or less, not readable as an image,
/// or no copy at half its bytes or less).
#[napi]
pub async fn preview(image: String, dir: String) -> Option<Thumbnail> {
    let found = tokio::task::spawn_blocking(move || preview_of(Path::new(&image), Path::new(&dir))).await.ok().flatten()?;
    Some(Thumbnail { path: found.0.to_string_lossy().into_owned(), kind: found.1.to_string() })
}

#[napi(object)]
pub struct Hashed {
    /// The ThumbHash, base64.
    pub hash: String,
    /// The image as it is seen (turned as its EXIF says).
    pub width: u32,
    pub height: u32,
}

/// thumbs.rs `keep`, for one image: its ThumbHash, decoded once, and with `dir` its thumbnail made from the same decoding
/// after (off the caller's thread, not waited for) when the image is over 24 KiB and has none yet. Null when it is not
/// readable as an image. Which images (by the attachment's name): the caller's.
#[napi]
pub async fn thumbhash(image: String, dir: Option<String>) -> Option<Hashed> {
    tokio::task::spawn_blocking(move || {
        let path = PathBuf::from(&image);
        let decoded = decode(&path)?;
        let hashed = Hashed { hash: hash(&decoded), width: decoded.width(), height: decoded.height() };
        let len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        if let Some(dir) = dir.filter(|_| len > SMALL) {
            let (dir, id) = (PathBuf::from(dir), id_of(&path));
            std::thread::spawn(move || {
                if kept(&dir, &id, &THUMB).is_none() {
                    let _ = make(decoded, len, &dir, &id, &THUMB);
                }
            });
        }
        Some(hashed)
    })
    .await
    .ok()
    .flatten()
}
