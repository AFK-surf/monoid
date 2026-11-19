// Whether an app on this machine holds the pointer (a game, a 3D view, a page's Pointer Lock): said to the station as
// message 4 `{pointerLock}` as it changes, so the viewer's app sends its moves as relative ones. A hidden pointer alone
// is never enough (a full-screen video or a slideshow hides an idle one, and shows it a frame or two after it moves):
// it takes the pointer hidden by an app (not by touch or a pen: CURSOR_SUPPRESSED is never a sign), clipped to less
// than the desktop or its window covering its monitor, in two samples in a row with moves between them for 100 ms;
// two samples in a row without it, or another window in front, let go. Hidden includes a pointer whose picture is all
// transparent (as games set one rather than hide it): drawn on black and on white, every pixel the background's.
// Sampled every 50 ms on a thread of its own, its GDI work between two looks at the foreground and the cursor that
// must agree (else no sample), in per-monitor DPI.

/// One sample.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample {
    /// Its time (ms, monotonic).
    pub at: f64,
    /// The pointer not shown: hidden, suppressed or transparent.
    pub hidden: bool,
    /// Why, where known: Some(true) an app hid it, Some(false) touch or a pen did; None not known.
    pub app_hidden: Option<bool>,
    /// Clipped to a rectangle smaller than the virtual desktop.
    pub confined: bool,
    /// The foreground window covers its monitor.
    pub fullscreen: bool,
    /// The foreground window.
    pub foreground: isize,
}

/// The moves (non-zero, finite: the viewer's posted ones) since the last sample: the first's time and the last's.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Moves {
    pub first: Option<f64>,
    pub last: Option<f64>,
}

impl Moves {
    pub fn add(&mut self, at: f64) {
        if self.first.is_none() {
            self.first = Some(at);
        }
        self.last = Some(at);
    }
}

pub const ENTER_MS: f64 = 100.0;

/// The two-sample rule.
#[derive(Default)]
pub struct Detector {
    locked: bool,
    last: Option<(Sample, bool)>,
    moving_since: Option<f64>,
}

impl Detector {
    /// A sample (None: none had this time) and the moves since the one before; whether it is held now.
    pub fn take(&mut self, sample: Option<Sample>, moves: Moves) -> bool {
        let Some(s) = sample else {
            return self.locked;
        };
        if let Some((p, _)) = self.last {
            if p.foreground != s.foreground {
                *self = Detector::default();
            }
        }
        let evidence = s.hidden && s.app_hidden != Some(false) && (s.confined || s.fullscreen);
        if let Some((p, was)) = self.last {
            if evidence && was {
                if let Some(last) = moves.last {
                    if last > p.at && last <= s.at && self.moving_since.is_none() {
                        self.moving_since = Some(moves.first.unwrap_or(last).max(p.at + 1.0));
                    }
                }
                if let Some(since) = self.moving_since {
                    if s.at - since >= ENTER_MS {
                        self.locked = true;
                    }
                }
            } else if !evidence && !was {
                self.locked = false;
            }
        }
        if !evidence {
            self.moving_since = None;
        }
        self.last = Some((s, evidence));
        self.locked
    }
}

/// Whether a rectangle a clip reads is the whole virtual desktop (no clip: Windows says the whole of it), else a
/// clip within it smaller than it.
pub fn confined(clip: (i32, i32, i32, i32), desktop: (i32, i32, i32, i32)) -> bool {
    let (l, t, r, b) = clip;
    let (dl, dt, dr, db) = desktop;
    if clip == desktop || r - l < 1 || b - t < 1 {
        return false;
    }
    l >= dl && t >= dt && r <= dr && b <= db && (r - l < dr - dl || b - t < db - dt)
}

/// Whether a window's rectangle covers its monitor's.
pub fn covers(window: (i32, i32, i32, i32), monitor: (i32, i32, i32, i32)) -> bool {
    window.0 <= monitor.0 && window.1 <= monitor.1 && window.2 >= monitor.2 && window.3 >= monitor.3
}

/// Whether a cursor drawn on black and on white (each pixel's RGB, the low 24 bits) left both as they were.
pub fn transparent(on_black: &[u32], on_white: &[u32]) -> bool {
    !on_black.is_empty() && on_black.iter().all(|p| p & 0xffffff == 0) && on_white.iter().all(|p| p & 0xffffff == 0xffffff)
}

#[cfg(windows)]
pub use sampler::Watch;

#[cfg(windows)]
mod sampler {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use windows::Win32::Foundation::{HWND, RECT};
    use windows::Win32::Graphics::Gdi::*;
    use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext};
    use windows::Win32::UI::WindowsAndMessaging::*;

    use super::{Detector, Moves, Sample, confined, covers, transparent};
    use crate::Out;

    /// The thread that samples, and the moves it is told of.
    #[derive(Clone)]
    pub struct Watch {
        moves: Arc<Mutex<Moves>>,
        start: Instant,
        on: Arc<AtomicBool>,
    }

    impl Watch {
        pub fn start(out: Out) -> Watch {
            let watch = Watch { moves: Arc::new(Mutex::new(Moves::default())), start: Instant::now(), on: Arc::new(AtomicBool::new(true)) };
            let w = watch.clone();
            std::thread::spawn(move || {
                unsafe {
                    let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
                }
                let mut detector = Detector::default();
                let mut said = false;
                while w.on.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(50));
                    // (the sample's time and the moves taken under one lock: none counted twice, none lost)
                    let (at, moves) = {
                        let mut m = w.moves.lock().unwrap();
                        (w.ms(), std::mem::take(&mut *m))
                    };
                    let locked = detector.take(sample(at), moves);
                    if locked != said {
                        said = locked;
                        out.json(4, serde_json::json!({ "pointerLock": locked }));
                    }
                }
            });
            watch
        }

        fn ms(&self) -> f64 {
            self.start.elapsed().as_secs_f64() * 1000.0
        }

        /// One of the viewer's moves posted.
        pub fn moved(&self) {
            let at = self.ms();
            self.moves.lock().unwrap().add(at);
        }

        pub fn stop(&self) {
            self.on.store(false, Ordering::SeqCst);
        }
    }

    fn cursor() -> Option<CURSORINFO> {
        let mut info = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
        unsafe { GetCursorInfo(&mut info) }.ok()?;
        Some(info)
    }

    fn rect(r: RECT) -> (i32, i32, i32, i32) {
        (r.left, r.top, r.right, r.bottom)
    }

    /// One sample, or none where the cursor or the foreground changed while it was taken.
    fn sample(at: f64) -> Option<Sample> {
        let before = cursor()?;
        let front = unsafe { GetForegroundWindow() };
        let showing = before.flags.0 & CURSOR_SHOWING.0 != 0;
        let suppressed = before.flags.0 & CURSOR_SUPPRESSED.0 != 0;
        let clear = if showing && !suppressed { invisible(before.hCursor) } else { Some(false) };
        let after = cursor()?;
        if after.flags != before.flags || after.hCursor != before.hCursor || unsafe { GetForegroundWindow() } != front {
            return None;
        }
        let clear = clear?;
        let desktop = unsafe {
            let (x, y) = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
            (x, y, x + GetSystemMetrics(SM_CXVIRTUALSCREEN), y + GetSystemMetrics(SM_CYVIRTUALSCREEN))
        };
        let mut clip = RECT::default();
        let confined = unsafe { GetClipCursor(&mut clip) }.is_ok() && confined(rect(clip), desktop);
        Some(Sample {
            at,
            hidden: !showing || suppressed || clear,
            app_hidden: Some(!suppressed && (!showing || clear)),
            confined,
            fullscreen: fullscreen(front),
            foreground: front.0 as isize,
        })
    }

    fn fullscreen(window: HWND) -> bool {
        unsafe {
            if window.0.is_null() || !IsWindowVisible(window).as_bool() || IsIconic(window).as_bool() {
                return false;
            }
            let mut r = RECT::default();
            if GetWindowRect(window, &mut r).is_err() {
                return false;
            }
            let monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONULL);
            if monitor.is_invalid() {
                return false;
            }
            let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(monitor, &mut info).as_bool() {
                return false;
            }
            covers(rect(r), rect(info.rcMonitor))
        }
    }

    /// Whether a cursor's picture (its first frame) is all transparent: drawn on black and on white, every pixel's RGB
    /// the background's; None where its size is not had (nothing proved).
    fn invisible(cursor: HCURSOR) -> Option<bool> {
        unsafe {
            let mut icon = ICONINFO::default();
            GetIconInfo(HICON(cursor.0), &mut icon).ok()?;
            let size = |b: HBITMAP| {
                let mut bm = BITMAP::default();
                (!b.is_invalid() && GetObjectW(HGDIOBJ(b.0), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut _ as *mut _)) != 0).then_some((bm.bmWidth, bm.bmHeight))
            };
            let (w, h) = match size(icon.hbmColor) {
                Some(s) => s,
                None => size(icon.hbmMask).map(|(w, h)| (w, h / 2)).unwrap_or((0, 0)),
            };
            if !icon.hbmColor.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(icon.hbmColor.0));
            }
            if !icon.hbmMask.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(icon.hbmMask.0));
            }
            if !(1..=512).contains(&w) || !(1..=512).contains(&h) {
                return None;
            }
            let black = drawn(cursor, w, h, 0x000000)?;
            let white = drawn(cursor, w, h, 0xffffff)?;
            Some(transparent(&black, &white))
        }
    }

    /// The cursor drawn on `background` in a 32-bit top-down DIB of `w`×`h`: its pixels.
    unsafe fn drawn(cursor: HCURSOR, w: i32, h: i32, background: u32) -> Option<Vec<u32>> {
        unsafe {
            let dc = CreateCompatibleDC(None);
            if dc.is_invalid() {
                return None;
            }
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER { biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32, biWidth: w, biHeight: -h, biPlanes: 1, biBitCount: 32, biCompression: BI_RGB.0, ..Default::default() },
                ..Default::default()
            };
            let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
            let Ok(dib) = CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) else {
                let _ = DeleteDC(dc);
                return None;
            };
            let old = SelectObject(dc, HGDIOBJ(dib.0));
            let pixels = std::slice::from_raw_parts_mut(bits as *mut u32, (w * h) as usize);
            pixels.fill(background);
            let ok = DrawIconEx(dc, 0, 0, HICON(cursor.0), w, h, 0, None, DI_NORMAL).is_ok();
            let _ = GdiFlush();
            let out = ok.then(|| pixels.to_vec());
            SelectObject(dc, old);
            let _ = DeleteObject(HGDIOBJ(dib.0));
            let _ = DeleteDC(dc);
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(at: f64, hidden: bool, fullscreen: bool) -> Option<Sample> {
        Some(Sample { at, hidden, app_hidden: Some(hidden), confined: false, fullscreen, foreground: 1 })
    }

    fn moved(at: &[f64]) -> Moves {
        let mut m = Moves::default();
        for &t in at {
            m.add(t);
        }
        m
    }

    #[test]
    fn hidden_full_screen_with_moves_is_held_after_100_ms() {
        let mut d = Detector::default();
        assert!(!d.take(s(0.0, true, true), Moves::default()));
        assert!(!d.take(s(50.0, true, true), moved(&[25.0])));
        assert!(!d.take(s(100.0, true, true), moved(&[75.0])));
        assert!(d.take(s(150.0, true, true), Moves::default()));
    }

    #[test]
    fn hidden_with_no_moves_is_never_held() {
        let mut d = Detector::default();
        for i in 0..20 {
            assert!(!d.take(s(i as f64 * 50.0, true, true), Moves::default()));
        }
    }

    #[test]
    fn hidden_then_shown_after_a_move_is_not_held_and_starts_again() {
        let mut d = Detector::default();
        assert!(!d.take(s(0.0, true, true), Moves::default()));
        assert!(!d.take(s(50.0, true, true), moved(&[25.0])));
        assert!(!d.take(s(100.0, false, true), moved(&[75.0])));
        assert!(!d.take(s(150.0, true, true), Moves::default()));
        assert!(!d.take(s(200.0, true, true), moved(&[180.0])));
        assert!(!d.take(s(250.0, true, true), moved(&[230.0])));
        assert!(d.take(s(300.0, true, true), moved(&[290.0])));
    }

    #[test]
    fn two_samples_without_it_let_go_one_does_not() {
        let mut d = Detector::default();
        d.take(s(0.0, true, true), Moves::default());
        d.take(s(50.0, true, true), moved(&[25.0]));
        d.take(s(100.0, true, true), moved(&[75.0]));
        assert!(d.take(s(150.0, true, true), Moves::default()));
        assert!(d.take(s(200.0, false, true), Moves::default()));
        assert!(d.take(s(250.0, true, true), Moves::default()));
        assert!(d.take(s(300.0, false, true), Moves::default()));
        assert!(!d.take(s(350.0, false, true), Moves::default()));
    }

    #[test]
    fn touch_suppressing_it_is_never_held() {
        let mut d = Detector::default();
        for i in 0..20 {
            let at = i as f64 * 50.0;
            let sample = Sample { at, hidden: true, app_hidden: Some(false), confined: true, fullscreen: true, foreground: 1 };
            assert!(!d.take(Some(sample), moved(&[at - 10.0])));
        }
    }

    #[test]
    fn hidden_but_neither_clipped_nor_full_screen_is_not_held() {
        let mut d = Detector::default();
        for i in 0..20 {
            let at = i as f64 * 50.0;
            assert!(!d.take(s(at, true, false), moved(&[at - 10.0])));
        }
    }

    #[test]
    fn another_window_in_front_lets_go_at_once() {
        let mut d = Detector::default();
        d.take(s(0.0, true, true), Moves::default());
        d.take(s(50.0, true, true), moved(&[25.0]));
        d.take(s(100.0, true, true), moved(&[75.0]));
        assert!(d.take(s(150.0, true, true), Moves::default()));
        let other = Sample { foreground: 2, ..s(200.0, true, true).unwrap() };
        assert!(!d.take(Some(other), Moves::default()));
    }

    #[test]
    fn no_sample_keeps_what_it_was() {
        let mut d = Detector::default();
        d.take(s(0.0, true, true), Moves::default());
        d.take(s(50.0, true, true), moved(&[25.0]));
        d.take(s(100.0, true, true), moved(&[75.0]));
        assert!(d.take(s(150.0, true, true), Moves::default()));
        assert!(d.take(None, Moves::default()));
    }

    #[test]
    fn a_clip_is_less_than_the_desktop() {
        let desktop = (0, 0, 3840, 1080);
        assert!(!confined(desktop, desktop));
        assert!(confined((0, 0, 1920, 1080), desktop));
        assert!(confined((0, 0, 3839, 1080), desktop));
        assert!(!confined((-10, 0, 100, 100), desktop));
        assert!(!confined((10, 10, 10, 20), desktop));
    }

    #[test]
    fn a_window_covering_its_monitor_is_full_screen() {
        assert!(covers((0, 0, 1920, 1080), (0, 0, 1920, 1080)));
        assert!(covers((-8, -8, 1928, 1088), (0, 0, 1920, 1080)));
        assert!(!covers((0, 0, 1920, 1040), (0, 0, 1920, 1080)));
    }

    #[test]
    fn a_cursor_is_transparent_only_on_both_backgrounds() {
        assert!(transparent(&[0xff000000, 0], &[0x00ffffff, 0xffffffff]));
        // a white pointer: on black it shows
        assert!(!transparent(&[0xffffff, 0], &[0xffffff, 0xffffff]));
        // a black one: on white it shows
        assert!(!transparent(&[0, 0], &[0, 0xffffff]));
        assert!(!transparent(&[], &[]));
    }
}
