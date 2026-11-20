// Frame pacing (`Gate`), periodic keyframe clock (`KeyClock`), and 150ms still-frame refinement (`StillRefiner`).

pub const AUTO_FPS: u32 = 60;
pub const MAX_FPS: u32 = 120;
pub const KEY_EVERY_MS: f64 = 10_000.0;
pub const STILL_REFINE_MS: f64 = 150.0;

/// Encoder target FPS (clamped to 1..=AUTO_FPS).
pub fn encoder_fps(asked: Option<u32>) -> u32 {
    asked.unwrap_or(AUTO_FPS).clamp(1, AUTO_FPS)
}

/// Requested capture FPS (clamped to 1..=MAX_FPS).
pub fn fps(v: Option<u64>) -> Option<u32> {
    v.map(|n| n.clamp(1, MAX_FPS as u64) as u32)
}

/// Periodic keyframe clock (every `KEY_EVERY_MS`).
#[derive(Default)]
pub struct KeyClock {
    last: Option<f64>,
}

impl KeyClock {
    pub fn due(&self, now: f64) -> bool {
        self.last.is_some_and(|last| now - last >= KEY_EVERY_MS)
    }

    pub fn keyed(&mut self, now: f64) {
        self.last = Some(now);
    }
}

/// Frame rate gate matching `station/src/mesh/screen-pace.ts` and `station/native/screen/src/pace.rs`.
pub struct Gate {
    gap: Option<f64>,
    due: f64,
}

impl Gate {
    pub fn new(fps: Option<u32>) -> Self {
        Self {
            gap: fps.filter(|&f| f > 0).map(|f| 1000.0 / f as f64),
            due: f64::NEG_INFINITY,
        }
    }

    pub fn open(&self, now: f64) -> bool {
        self.gap.is_none() || now >= self.due
    }

    /// Milliseconds remaining until the gate opens (0.0 if already open).
    pub fn wait_ms(&self, now: f64) -> f64 {
        match self.gap {
            None => 0.0,
            Some(_) => (self.due - now).max(0.0),
        }
    }

    pub fn went(&mut self, now: f64) {
        if let Some(gap) = self.gap {
            self.due = (self.due + gap).max(now + gap / 2.0);
        }
    }
}

/// 150ms still-frame refinement state machine.
/// When a frame is encoded under a constrained bitrate, arming the refiner triggers one higher-quality
/// refinement frame once the screen has been still for `STILL_REFINE_MS`. After that refinement frame is
/// sent, it stays quiet until new damage occurs.
#[derive(Default)]
pub struct StillRefiner {
    pending_since: Option<f64>,
}

impl StillRefiner {
    /// Record that a motion/normal frame was encoded at `now` (ms).
    /// If `constrained` is true, a refinement frame will be scheduled after `STILL_REFINE_MS` of stillness.
    pub fn on_encoded(&mut self, now: f64, constrained: bool) {
        self.pending_since = if constrained { Some(now) } else { None };
    }

    /// Record new screen damage (resets any pending timer until the new frame is encoded).
    pub fn on_damage(&mut self) {
        self.pending_since = None;
    }

    /// Mark that the refinement frame has been sent; stays silent until next constrained encode.
    pub fn on_refined(&mut self) {
        self.pending_since = None;
    }

    /// Whether a still refinement frame is due now (ms).
    pub fn due(&self, now: f64) -> bool {
        self.pending_since
            .is_some_and(|since| now - since >= STILL_REFINE_MS)
    }

    /// Milliseconds until refinement is due, or `None` if no refinement is pending.
    pub fn wait_ms(&self, now: f64) -> Option<f64> {
        self.pending_since
            .map(|since| (since + STILL_REFINE_MS - now).max(0.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(fps: Option<u32>, every: f64, ms: f64) -> Vec<f64> {
        let mut gate = Gate::new(fps);
        let mut went = Vec::new();
        let mut t = 0.0;
        while t < ms {
            if gate.open(t) {
                gate.went(t);
                went.push(t);
            }
            t += every;
        }
        went
    }

    #[test]
    fn gate_caps_frame_rate() {
        for target in [15, 30, 60, 90, 120] {
            let went = run(Some(target), 1000.0 / 240.0, 10_000.0);
            for (i, &t) in went.iter().enumerate() {
                let within = went[i..].iter().take_while(|&&u| u < t + 1000.0).count();
                assert!(within <= target as usize + 1);
            }
            assert!(went.len() as f64 >= target as f64 * 10.0 * 0.95);
        }
    }

    #[test]
    fn key_clock_fires_every_ten_seconds() {
        let mut clock = KeyClock::default();
        assert!(!clock.due(0.0));
        clock.keyed(0.0);
        assert!(!clock.due(9_999.0));
        assert!(clock.due(10_000.0));
        clock.keyed(6_000.0);
        assert!(!clock.due(10_000.0));
        assert!(clock.due(16_000.0));
    }

    #[test]
    fn still_refiner_fires_once_after_150ms_and_stays_quiet() {
        let mut r = StillRefiner::default();
        assert!(!r.due(0.0));
        assert_eq!(r.wait_ms(0.0), None);

        // Unconstrained encode does not arm refinement.
        r.on_encoded(100.0, false);
        assert!(!r.due(300.0));
        assert_eq!(r.wait_ms(300.0), None);

        // Constrained encode arms refinement for 150ms later.
        r.on_encoded(100.0, true);
        assert!(!r.due(249.0));
        assert_eq!(r.wait_ms(200.0), Some(50.0));
        assert!(r.due(250.0));
        assert_eq!(r.wait_ms(260.0), Some(0.0));

        // After refinement, stays quiet indefinitely.
        r.on_refined();
        assert!(!r.due(10_000.0));
        assert_eq!(r.wait_ms(10_000.0), None);

        // New damage cancels pending refinement until re-encoded.
        r.on_encoded(500.0, true);
        r.on_damage();
        assert!(!r.due(700.0));
    }

    #[test]
    fn encoder_fps_clamps() {
        assert_eq!(encoder_fps(None), AUTO_FPS);
        assert_eq!(encoder_fps(Some(120)), 60);
        assert_eq!(encoder_fps(Some(30)), 30);
        assert_eq!(fps(Some(0)), Some(1));
        assert_eq!(fps(Some(240)), Some(MAX_FPS));
    }
}
