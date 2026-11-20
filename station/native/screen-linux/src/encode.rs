// Software H.264 (OpenH264, BSD-2-Clause, compiled from source) and JPEG encoders.
// OpenH264 supports live bitrate updates via SetOption(ENCODER_OPTION_BITRATE / MAX_BITRATE)
// without restarting the encoder.

use crate::avc;
use openh264::encoder::{
    BitRate, Encoder, EncoderConfig, FrameRate, Profile, RateControlMode, UsageType,
};
use openh264::formats::YUVSlices;
use openh264_sys2::{
    ENCODER_OPTION_BITRATE, ENCODER_OPTION_MAX_BITRATE, ENCODER_OPTION_TRACE_LEVEL, SBitrateInfo,
    SPATIAL_LAYER_0, SPATIAL_LAYER_ALL, WELS_LOG_QUIET,
};
use std::ffi::c_void;

pub const DEFAULT_BITRATE: u32 = 2_000_000;
pub const MIN_BITRATE: u32 = 150_000;
pub const MAX_BITRATE: u32 = 25_000_000;

pub struct H264Encoder {
    encoder: Encoder,
    width: usize,
    height: usize,
    bitrate: u32,
    fps: u32,
    initialized: bool,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
    buf: Vec<u8>,
}

impl H264Encoder {
    pub fn new(width: u32, height: u32, bitrate: u32, fps: u32) -> Result<Self, String> {
        let bps = bitrate.clamp(MIN_BITRATE, MAX_BITRATE);
        let fps = fps.clamp(1, 60);
        let config = EncoderConfig::new()
            .bitrate(BitRate::from_bps(bps))
            .max_frame_rate(FrameRate::from_hz(fps as f32))
            .usage_type(UsageType::ScreenContentRealTime)
            .rate_control_mode(RateControlMode::Bitrate)
            .profile(Profile::Baseline)
            .skip_frames(false)
            .debug(false);

        let mut encoder = Encoder::with_api_config(openh264::OpenH264API::from_source(), config)
            .map_err(|e| format!("openh264 init: {e}"))?;

        // Silence OpenH264 trace output BEFORE lazy initialize_ext runs on the first frame so
        // nothing ever leaks onto stdout (which carries the binary pipe protocol).
        unsafe {
            let mut quiet = WELS_LOG_QUIET as i32;
            let _ = encoder
                .raw_api()
                .set_option(ENCODER_OPTION_TRACE_LEVEL, (&mut quiet as *mut i32).cast());
        }

        Ok(Self {
            encoder,
            width: width as usize,
            height: height as usize,
            bitrate: bps,
            fps,
            initialized: false,
            sps: None,
            pps: None,
            buf: Vec::new(),
        })
    }

    #[cfg(test)]
    pub fn bitrate(&self) -> u32 {
        self.bitrate
    }

    /// Hot-update target and max bitrate without restarting the encoder.
    pub fn set_bitrate(&mut self, bps: u32) -> Result<(), String> {
        let clamped = bps.clamp(MIN_BITRATE, MAX_BITRATE);
        let prev = self.bitrate;
        self.bitrate = clamped;
        if !self.initialized {
            let fresh = Self::new(self.width as u32, self.height as u32, clamped, self.fps)?;
            *self = fresh;
            return Ok(());
        }
        let target = clamped as i32;
        let max_bps = ((clamped as u64 * 12 / 10).min(MAX_BITRATE as u64)) as i32;
        unsafe {
            let raw = self.encoder.raw_api();
            let set = |opt, layer, bps| -> i32 {
                let mut info = SBitrateInfo {
                    iLayer: layer,
                    iBitrate: bps,
                };
                raw.set_option(opt, (&mut info as *mut SBitrateInfo).cast::<c_void>())
            };
            if clamped >= prev {
                // Raise max bitrate (overall + layer 0) before target bitrate.
                let rc_m_all = set(ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_ALL, max_bps);
                let rc_m_0 = set(ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_0, max_bps);
                if rc_m_all != 0 && rc_m_0 != 0 {
                    return Err(format!("openh264 set max bitrate failed: all={rc_m_all} l0={rc_m_0}"));
                }
                let rc_t_0 = set(ENCODER_OPTION_BITRATE, SPATIAL_LAYER_0, target);
                let rc_t_all = set(ENCODER_OPTION_BITRATE, SPATIAL_LAYER_ALL, target);
                if rc_t_0 != 0 && rc_t_all != 0 {
                    return Err(format!("openh264 set bitrate failed: l0={rc_t_0} all={rc_t_all}"));
                }
            } else {
                // Lower target bitrate (layer 0 + overall) before max bitrate.
                let rc_t_0 = set(ENCODER_OPTION_BITRATE, SPATIAL_LAYER_0, target);
                let rc_t_all = set(ENCODER_OPTION_BITRATE, SPATIAL_LAYER_ALL, target);
                if rc_t_0 != 0 && rc_t_all != 0 {
                    return Err(format!("openh264 set bitrate failed: l0={rc_t_0} all={rc_t_all}"));
                }
                let rc_m_0 = set(ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_0, max_bps);
                let rc_m_all = set(ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_ALL, max_bps);
                if rc_m_all != 0 && rc_m_0 != 0 {
                    return Err(format!("openh264 set max bitrate failed: all={rc_m_all} l0={rc_m_0}"));
                }
            }
        }
        Ok(())
    }

    pub fn avcc(&self) -> Option<Vec<u8>> {
        match (&self.sps, &self.pps) {
            (Some(s), Some(p)) => Some(avc::avcc(s, p)),
            _ => None,
        }
    }

    /// Encode one I420 frame. Returns `(picture, config_changed)`.
    pub fn encode_i420(
        &mut self,
        y: &[u8],
        u: &[u8],
        v: &[u8],
        force_key: bool,
    ) -> Result<(avc::Picture, bool), String> {
        if force_key && self.initialized {
            self.encoder.force_intra_frame();
        }
        let yuv = YUVSlices::new(
            (y, u, v),
            (self.width, self.height),
            (self.width, self.width / 2, self.width / 2),
        );
        let bs = self
            .encoder
            .encode(&yuv)
            .map_err(|e| format!("openh264 encode: {e}"))?;
        self.initialized = true;
        self.buf.clear();
        bs.write_vec(&mut self.buf);
        let pic = avc::picture(&self.buf);
        let mut config_changed = false;
        if let Some(ref sps) = pic.sps {
            if self.sps.as_ref() != Some(sps) {
                self.sps = Some(sps.clone());
                config_changed = true;
            }
        }
        if let Some(ref pps) = pic.pps {
            if self.pps.as_ref() != Some(pps) {
                self.pps = Some(pps.clone());
                config_changed = true;
            }
        }
        Ok((pic, config_changed))
    }
}

/// Software JPEG encoder (BGRA -> JPEG).
pub fn encode_jpeg_bgra(bgra: &[u8], width: u32, height: u32, quality: u8) -> Result<Vec<u8>, String> {
    let mut rgb = Vec::with_capacity((width as usize) * (height as usize) * 3);
    for px in bgra.chunks_exact(4) {
        rgb.push(px[2]); // R
        rgb.push(px[1]); // G
        rgb.push(px[0]); // B
    }
    let mut out = Vec::with_capacity((width as usize * height as usize) / 4);
    let encoder = jpeg_encoder::Encoder::new(&mut out, quality);
    encoder
        .encode(&rgb, width as u16, height as u16, jpeg_encoder::ColorType::Rgb)
        .map_err(|e| format!("jpeg encode: {e}"))?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::bgra_to_i420;

    fn test_frame(w: usize, h: usize, seed: u8) -> Vec<u8> {
        let mut bgra = vec![0u8; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let off = (y * w + x) * 4;
                bgra[off] = ((x + seed as usize) & 0xff) as u8;
                bgra[off + 1] = ((y + seed as usize) & 0xff) as u8;
                bgra[off + 2] = ((x ^ y) as u8).wrapping_add(seed);
                bgra[off + 3] = 255;
            }
        }
        bgra
    }

    #[test]
    fn h264_encodes_and_hot_updates_bitrate_without_restart() {
        let (w, h) = (320usize, 180usize);
        let mut enc = H264Encoder::new(w as u32, h as u32, 1_000_000, 30).unwrap();
        let (mut y, mut u, mut v) = (Vec::new(), Vec::new(), Vec::new());

        let f0 = test_frame(w, h, 0);
        bgra_to_i420(&f0, w, h, &mut y, &mut u, &mut v);
        let (p0, changed0) = enc.encode_i420(&y, &u, &v, false).unwrap();
        assert!(p0.key, "first frame must be an IDR keyframe");
        assert!(changed0, "first frame must emit SPS/PPS");
        assert!(!p0.data.is_empty());
        let avcc = enc.avcc().expect("avcC present");
        assert_eq!(avcc[0], 1);

        // Hot-update bitrate up and down mid-stream without restarting.
        enc.set_bitrate(2_500_000).unwrap();
        assert_eq!(enc.bitrate(), 2_500_000);

        let mut f1 = f0.clone();
        for y in 16..48 {
            for x in 16..48 {
                let off = (y * w + x) * 4;
                f1[off] = 240;
                f1[off + 1] = 40;
                f1[off + 2] = 10;
            }
        }
        bgra_to_i420(&f1, w, h, &mut y, &mut u, &mut v);
        let (p1, changed1) = enc.encode_i420(&y, &u, &v, false).unwrap();
        assert!(!p1.key, "subsequent frame after bitrate raise should be P-frame (no restart)");
        assert!(!changed1);
        assert!(!p1.data.is_empty());

        enc.set_bitrate(500_000).unwrap();
        assert_eq!(enc.bitrate(), 500_000);
        let mut f2 = f1.clone();
        for y in 48..80 {
            for x in 48..80 {
                let off = (y * w + x) * 4;
                f2[off] = 10;
                f2[off + 1] = 220;
                f2[off + 2] = 30;
            }
        }
        bgra_to_i420(&f2, w, h, &mut y, &mut u, &mut v);
        let (p2_low, _) = enc.encode_i420(&y, &u, &v, false).unwrap();
        assert!(!p2_low.key, "subsequent frame after bitrate lower should be P-frame (no restart)");
        assert!(!p2_low.data.is_empty());

        // Forced keyframe works cleanly.
        let (p2, _) = enc.encode_i420(&y, &u, &v, true).unwrap();
        assert!(p2.key, "forced keyframe must be IDR");
    }

    #[test]
    fn jpeg_produces_valid_soi_and_eoi() {
        let bgra = test_frame(64, 48, 5);
        let jpg = encode_jpeg_bgra(&bgra, 64, 48, 80).unwrap();
        assert!(jpg.len() > 100);
        assert_eq!(&jpg[..2], &[0xff, 0xd8]);
        assert_eq!(&jpg[jpg.len() - 2..], &[0xff, 0xd9]);
    }
}
