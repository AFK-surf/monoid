// Native Linux X11 backend (pure Rust via `x11rb`):
// - Capture: MIT-SHM (`shm::get_image`) with automatic fallback to `xproto::get_image`.
//   SHM segments are immediately marked `IPC_RMID` after attach so even SIGKILL leaves zero SHM leaks.
// - Change notification: XDamage (`NON_EMPTY`) + XFixes cursor events, awaited via `poll()` on the X11 fd.
// - Input: persistent XTest connection with 16-slot LRU `SpareKeyPool` for Unicode typing synced by `GetInputFocus`.

use crate::cursor_image;
use crate::input_queue::{InputOp, MouseKind, SpareKeyPool};
use std::collections::HashSet;
use std::os::fd::AsRawFd;
use std::ptr;
use x11rb::connection::Connection;
use x11rb::protocol::damage::{self, ConnectionExt as DamageExt, ReportLevel};
use x11rb::protocol::shm::{self, ConnectionExt as ShmExt};
use x11rb::protocol::xfixes::{ConnectionExt as XfixesExt, CursorNotifyMask};
use x11rb::protocol::xproto::{
    ConnectionExt as XprotoExt, ImageFormat, Screen, Window, BUTTON_PRESS_EVENT,
    BUTTON_RELEASE_EVENT, KEY_PRESS_EVENT, KEY_RELEASE_EVENT, MOTION_NOTIFY_EVENT,
};
use x11rb::protocol::xtest::ConnectionExt as XtestExt;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::CURRENT_TIME;

pub struct CursorInfo {
    pub x: f64,
    pub y: f64,
    pub shape: String,
    pub custom_payload: Option<Vec<u8>>,
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub hot_x: i32,
    pub hot_y: i32,
}

/// Probe X11 display availability and dimensions.
pub fn probe() -> Result<(u32, u32), String> {
    let (conn, screen_num) = RustConnection::connect(None).map_err(|e| format!("x11 connect: {e}"))?;
    let screen = &conn.setup().roots[screen_num];
    Ok((screen.width_in_pixels as u32, screen.height_in_pixels as u32))
}

struct ShmBuffer {
    seg: shm::Seg,
    ptr: *mut u8,
    len: usize,
}

impl ShmBuffer {
    fn new(conn: &RustConnection, width: u32, height: u32) -> Option<Self> {
        conn.shm_query_version().ok()?.reply().ok()?;
        let len = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
        if len == 0 {
            return None;
        }
        let shmid = unsafe {
            libc::shmget(
                libc::IPC_PRIVATE,
                len,
                libc::IPC_CREAT | libc::IPC_EXCL | 0o600,
            )
        };
        if shmid < 0 {
            return None;
        }
        let ptr = unsafe { libc::shmat(shmid, ptr::null(), 0) };
        if ptr == (-1isize) as *mut libc::c_void {
            unsafe {
                libc::shmctl(shmid, libc::IPC_RMID, ptr::null_mut());
            }
            return None;
        }
        let seg = match conn.generate_id() {
            Ok(id) => id,
            Err(_) => {
                unsafe {
                    libc::shmdt(ptr);
                    libc::shmctl(shmid, libc::IPC_RMID, ptr::null_mut());
                }
                return None;
            }
        };
        let attached = conn
            .shm_attach(seg, shmid as u32, false)
            .ok()
            .and_then(|c| c.check().ok())
            .is_some();
        // Immediately mark for removal so kernel reclaims the segment automatically when both
        // this process and the X server detach (even on SIGKILL).
        unsafe {
            libc::shmctl(shmid, libc::IPC_RMID, ptr::null_mut());
        }
        if !attached {
            unsafe {
                libc::shmdt(ptr);
            }
            return None;
        }
        Some(Self {
            seg,
            ptr: ptr as *mut u8,
            len,
        })
    }

    fn as_slice(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    fn detach(&self, conn: &RustConnection) {
        let _ = conn.shm_detach(self.seg);
        let _ = conn.flush();
    }
}

impl Drop for ShmBuffer {
    fn drop(&mut self) {
        unsafe {
            libc::shmdt(self.ptr as *const libc::c_void);
        }
    }
}

pub struct X11Capture {
    conn: RustConnection,
    root: Window,
    width: u32,
    height: u32,
    shm: Option<ShmBuffer>,
    damage: Option<damage::Damage>,
    has_xfixes: bool,
    sent_cursor_ids: HashSet<String>,
    last_cursor: Option<(f64, f64, String)>,
    cached_shape: String,
    cached_rgba: Vec<u8>,
    cached_cw: u32,
    cached_ch: u32,
    cached_hot_x: i32,
    cached_hot_y: i32,
    cursor_shape_loaded: bool,
}

impl X11Capture {
    pub fn open() -> Result<Self, String> {
        let (conn, screen_num) =
            RustConnection::connect(None).map_err(|e| format!("x11 connect: {e}"))?;
        let screen: &Screen = &conn.setup().roots[screen_num];
        let root = screen.root;
        let width = screen.width_in_pixels as u32;
        let height = screen.height_in_pixels as u32;
        if width < 2 || height < 2 {
            return Err(format!("invalid x11 display size {width}x{height}"));
        }

        let shm = ShmBuffer::new(&conn, width, height);

        let damage = (|| {
            conn.damage_query_version(1, 1).ok()?.reply().ok()?;
            let id = conn.generate_id().ok()?;
            conn.damage_create(id, root, ReportLevel::NON_EMPTY)
                .ok()?
                .check()
                .ok()?;
            Some(id)
        })();

        let has_xfixes = (|| {
            conn.xfixes_query_version(4, 0).ok()?.reply().ok()?;
            conn.xfixes_select_cursor_input(root, CursorNotifyMask::DISPLAY_CURSOR)
                .ok()?
                .check()
                .ok()?;
            Some(true)
        })()
        .unwrap_or(false);

        let _ = conn.flush();

        Ok(Self {
            conn,
            root,
            width,
            height,
            shm,
            damage,
            has_xfixes,
            sent_cursor_ids: HashSet::new(),
            last_cursor: None,
            cached_shape: "default".to_string(),
            cached_rgba: Vec::new(),
            cached_cw: 0,
            cached_ch: 0,
            cached_hot_x: 0,
            cached_hot_y: 0,
            cursor_shape_loaded: false,
        })
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn has_damage(&self) -> bool {
        self.damage.is_some()
    }

    pub fn capture_label(&self) -> &'static str {
        match (self.shm.is_some(), self.damage.is_some()) {
            (true, true) => "X11 (MIT-SHM+XDamage)",
            (true, false) => "X11 (MIT-SHM)",
            (false, true) => "X11 (GetImage+XDamage)",
            (false, false) => "X11 (GetImage)",
        }
    }

    /// Wait up to `timeout_ms` for any X11 event on the socket fd.
    pub fn wait_fd(&self, timeout_ms: i32) -> bool {
        let fd = self.conn.stream().as_raw_fd();
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let rc = unsafe { libc::poll(&mut pfd, 1, timeout_ms.max(0)) };
        rc > 0 && (pfd.revents & libc::POLLIN) != 0
    }

    /// Drain pending X11 events. Returns `(screen_damaged, cursor_changed)`.
    pub fn poll_events(&self) -> (bool, bool) {
        let mut damaged = false;
        let mut cursor_changed = false;
        while let Ok(Some(ev)) = self.conn.poll_for_event() {
            match ev {
                Event::DamageNotify(_) => damaged = true,
                Event::XfixesCursorNotify(_) => cursor_changed = true,
                _ => {}
            }
        }
        if damaged {
            if let Some(d) = self.damage {
                let _ = self.conn.damage_subtract(d, 0u32, 0u32);
                let _ = self.conn.flush();
            }
        }
        (damaged, cursor_changed)
    }

    /// Capture the full screen into `out_bgra` (`width * height * 4` BGRA8).
    pub fn capture_bgra(&mut self, out_bgra: &mut Vec<u8>) -> Result<(), String> {
        let expected = (self.width as usize) * (self.height as usize) * 4;
        if let Some(ref shm) = self.shm {
            if let Ok(cookie) = self.conn.shm_get_image(
                self.root,
                0,
                0,
                self.width as u16,
                self.height as u16,
                !0u32,
                ImageFormat::Z_PIXMAP.into(),
                shm.seg,
                0,
            ) {
                if cookie.reply().is_ok() {
                    out_bgra.resize(expected, 0);
                    out_bgra.copy_from_slice(&shm.as_slice()[..expected]);
                    return Ok(());
                }
            }
        }

        // Fallback to standard GetImage.
        let reply = self
            .conn
            .get_image(
                ImageFormat::Z_PIXMAP,
                self.root,
                0,
                0,
                self.width as u16,
                self.height as u16,
                !0u32,
            )
            .map_err(|e| format!("x11 get_image: {e}"))?
            .reply()
            .map_err(|e| format!("x11 get_image reply: {e}"))?;
        if reply.data.len() < expected {
            return Err(format!(
                "x11 get_image short buffer: {} < {}",
                reply.data.len(),
                expected
            ));
        }
        out_bgra.resize(expected, 0);
        out_bgra.copy_from_slice(&reply.data[..expected]);
        Ok(())
    }

    /// Refresh XFixes cursor shape/image (only called on first frame or `XfixesCursorNotify`).
    /// Returns optional message 11 payload if a new custom cursor image should be emitted.
    fn refresh_cursor_shape(&mut self) -> Option<Vec<u8>> {
        self.cursor_shape_loaded = true;
        if !self.has_xfixes {
            return None;
        }
        let img = self.conn.xfixes_get_cursor_image_and_name().ok()?.reply().ok()?;
        let name = String::from_utf8_lossy(&img.name).to_string();
        let cw = img.width as u32;
        let ch = img.height as u32;
        let hot_x = img.xhot as i32;
        let hot_y = img.yhot as i32;
        let rgba = cursor_image::argb32_premul_to_rgba(&img.cursor_image);
        self.cached_cw = cw;
        self.cached_ch = ch;
        self.cached_hot_x = hot_x;
        self.cached_hot_y = hot_y;
        self.cached_rgba = rgba;

        if let Some(std_shape) = map_xcursor_name(&name) {
            self.cached_shape = std_shape.to_string();
            return None;
        }
        if cw > 0 && ch > 0 {
            let any_visible = self.cached_rgba.chunks_exact(4).any(|px| px[3] > 0);
            if !any_visible {
                self.cached_shape = "none".to_string();
                return None;
            }
            if let Some(head) = cursor_image::points(
                (cw, ch),
                (hot_x.max(0) as u32, hot_y.max(0) as u32),
                1.0,
            ) {
                if let Some(png) = cursor_image::encode_png(&self.cached_rgba, cw, ch) {
                    if let Some((id, payload)) = cursor_image::payload(head, &self.cached_rgba, &png)
                    {
                        let custom = format!("custom:{id}");
                        self.cached_shape = custom;
                        if !self.sent_cursor_ids.contains(&id) {
                            if self.sent_cursor_ids.len() >= 128 {
                                self.sent_cursor_ids.clear();
                            }
                            self.sent_cursor_ids.insert(id);
                            return Some(payload);
                        }
                        return None;
                    }
                }
            }
        }
        self.cached_shape = "default".to_string();
        None
    }

    /// Query pointer position (lightweight `query_pointer`) and optionally refresh XFixes cursor shape.
    /// When `only_if_changed` is true, returns `None` if `(x, y, shape)` is unchanged and no new custom image arrived.
    pub fn query_cursor(&mut self, refresh_shape: bool, only_if_changed: bool) -> Option<CursorInfo> {
        let custom_payload = if refresh_shape || !self.cursor_shape_loaded {
            self.refresh_cursor_shape()
        } else {
            None
        };
        let ptr_reply = self.conn.query_pointer(self.root).ok()?.reply().ok()?;
        let x = (ptr_reply.root_x as f64 / (self.width.max(1) as f64)).clamp(0.0, 1.0);
        let y = (ptr_reply.root_y as f64 / (self.height.max(1) as f64)).clamp(0.0, 1.0);

        if only_if_changed && custom_payload.is_none() {
            if let Some((lx, ly, ref ls)) = self.last_cursor {
                if (lx - x).abs() < 1e-5 && (ly - y).abs() < 1e-5 && ls == &self.cached_shape {
                    return None;
                }
            }
        }
        self.last_cursor = Some((x, y, self.cached_shape.clone()));
        Some(CursorInfo {
            x,
            y,
            shape: self.cached_shape.clone(),
            custom_payload,
            rgba: self.cached_rgba.clone(),
            width: self.cached_cw,
            height: self.cached_ch,
            hot_x: self.cached_hot_x,
            hot_y: self.cached_hot_y,
        })
    }
}

impl Drop for X11Capture {
    fn drop(&mut self) {
        if let Some(ref shm) = self.shm {
            shm.detach(&self.conn);
        }
        if let Some(d) = self.damage {
            let _ = self.conn.damage_destroy(d);
            let _ = self.conn.flush();
        }
    }
}

/// Map common X11 cursor theme names to CSS cursor names accepted by `source.ts` (`CURSOR_SHAPE`).
fn map_xcursor_name(name: &str) -> Option<&'static str> {
    match name {
        "left_ptr" | "default" | "arrow" | "top_left_arrow" => Some("default"),
        "xterm" | "text" | "ibeam" => Some("text"),
        "hand2" | "hand1" | "pointer" | "pointing_hand" => Some("pointer"),
        "fleur" | "move" | "all-scroll" | "size_all" => Some("move"),
        "crosshair" | "cross" | "tcross" | "plus" => Some("crosshair"),
        "watch" | "wait" => Some("wait"),
        "left_ptr_watch" | "progress" | "half-busy" => Some("progress"),
        "not-allowed" | "crossed_circle" | "no-drop" | "forbidden" => Some("not-allowed"),
        "grab" | "openhand" => Some("grab"),
        "grabbing" | "closedhand" => Some("grabbing"),
        "sb_h_double_arrow" | "ew-resize" | "col-resize" | "size_hor" | "e-resize" | "w-resize" => {
            Some("ew-resize")
        }
        "sb_v_double_arrow" | "ns-resize" | "row-resize" | "size_ver" | "n-resize" | "s-resize" => {
            Some("ns-resize")
        }
        "nesw-resize" | "size_bdiag" | "top_right_corner" | "bottom_left_corner" => {
            Some("nesw-resize")
        }
        "nwse-resize" | "size_fdiag" | "top_left_corner" | "bottom_right_corner" => {
            Some("nwse-resize")
        }
        "copy" | "dnd-copy" => Some("copy"),
        "alias" | "dnd-link" => Some("alias"),
        "context-menu" => Some("context-menu"),
        "help" | "question_arrow" => Some("help"),
        "zoom-in" => Some("zoom-in"),
        "zoom-out" => Some("zoom-out"),
        "none" | "blank" => Some("none"),
        _ => None,
    }
}

/// Persistent XTest input driver with 16-slot LRU Unicode keycode pool.
pub struct X11InputDriver {
    conn: RustConnection,
    root: Window,
    width: u32,
    height: u32,
    pool: SpareKeyPool,
    syms_per_keycode: u8,
}

impl X11InputDriver {
    pub fn open(width: u32, height: u32) -> Result<Self, String> {
        let (conn, screen_num) =
            RustConnection::connect(None).map_err(|e| format!("x11 input connect: {e}"))?;
        let root = conn.setup().roots[screen_num].root;
        let min_kc = conn.setup().min_keycode;
        let max_kc = conn.setup().max_keycode;
        let count = max_kc.saturating_sub(min_kc).saturating_add(1);

        let mut unused = Vec::new();
        let mut syms_per_keycode = 1u8;
        if let Ok(cookie) = conn.get_keyboard_mapping(min_kc, count) {
            if let Ok(reply) = cookie.reply() {
                syms_per_keycode = reply.keysyms_per_keycode.max(1);
                let step = syms_per_keycode as usize;
                for i in (0..count as usize).rev() {
                    let start = i * step;
                    let end = (start + step).min(reply.keysyms.len());
                    if reply.keysyms[start..end].iter().all(|&ks| ks == 0) {
                        unused.push(min_kc.saturating_add(i as u8));
                    }
                }
            }
        }

        Ok(Self {
            conn,
            root,
            width: width.max(1),
            height: height.max(1),
            pool: SpareKeyPool::new(&unused),
            syms_per_keycode,
        })
    }

    fn point(&self, x: f64, y: f64) -> (i16, i16) {
        let px = (x.clamp(0.0, 1.0) * (self.width.saturating_sub(1) as f64)).round() as i16;
        let py = (y.clamp(0.0, 1.0) * (self.height.saturating_sub(1) as f64)).round() as i16;
        (px, py)
    }

    fn x11_button(button: u8) -> u8 {
        match button {
            0 => 1, // left
            1 => 2, // middle
            2 => 3, // right
            _ => 1,
        }
    }

    pub fn apply(&mut self, op: &InputOp, is_cancelled: &dyn Fn() -> bool) {
        match op {
            InputOp::Mouse {
                kind,
                x,
                y,
                button,
                dx,
                dy,
                relative,
            } => match kind {
                MouseKind::Move => {
                    if *relative {
                        let rdx = dx.unwrap_or(0.0).round() as i16;
                        let rdy = dy.unwrap_or(0.0).round() as i16;
                        if rdx != 0 || rdy != 0 {
                            let _ = self.conn.xtest_fake_input(
                                MOTION_NOTIFY_EVENT,
                                1,
                                CURRENT_TIME,
                                self.root,
                                rdx,
                                rdy,
                                0,
                            );
                        }
                    } else {
                        let (px, py) = self.point(*x, *y);
                        let _ = self.conn.xtest_fake_input(
                            MOTION_NOTIFY_EVENT,
                            0,
                            CURRENT_TIME,
                            self.root,
                            px,
                            py,
                            0,
                        );
                    }
                    let _ = self.conn.flush();
                }
                MouseKind::Down | MouseKind::Up => {
                    if !*relative {
                        let (px, py) = self.point(*x, *y);
                        let _ = self.conn.xtest_fake_input(
                            MOTION_NOTIFY_EVENT,
                            0,
                            CURRENT_TIME,
                            self.root,
                            px,
                            py,
                            0,
                        );
                    }
                    let ev = if matches!(kind, MouseKind::Down) {
                        BUTTON_PRESS_EVENT
                    } else {
                        BUTTON_RELEASE_EVENT
                    };
                    let _ = self.conn.xtest_fake_input(
                        ev,
                        Self::x11_button(*button),
                        CURRENT_TIME,
                        self.root,
                        0,
                        0,
                        0,
                    );
                    let _ = self.conn.flush();
                }
            },
            InputOp::Wheel { x, y, dx, dy } => {
                if *x >= 0.0 && *y >= 0.0 {
                    let (px, py) = self.point(*x, *y);
                    let _ = self.conn.xtest_fake_input(
                        MOTION_NOTIFY_EVENT,
                        0,
                        CURRENT_TIME,
                        self.root,
                        px,
                        py,
                        0,
                    );
                }
                let emit_clicks = |conn: &RustConnection, root: Window, btn: u8, count: i32| {
                    for _ in 0..count.min(20) {
                        let _ = conn.xtest_fake_input(BUTTON_PRESS_EVENT, btn, CURRENT_TIME, root, 0, 0, 0);
                        let _ = conn.xtest_fake_input(BUTTON_RELEASE_EVENT, btn, CURRENT_TIME, root, 0, 0, 0);
                    }
                };
                let vy = dy.trunc() as i32;
                if vy != 0 {
                    emit_clicks(&self.conn, self.root, if vy > 0 { 5 } else { 4 }, vy.abs());
                }
                let vx = dx.trunc() as i32;
                if vx != 0 {
                    emit_clicks(&self.conn, self.root, if vx > 0 { 7 } else { 6 }, vx.abs());
                }
                let _ = self.conn.flush();
            }
            InputOp::Key { evdev, down } => {
                let kc = evdev.saturating_add(8);
                if kc <= 255 {
                    let ev = if *down { KEY_PRESS_EVENT } else { KEY_RELEASE_EVENT };
                    let _ = self.conn.xtest_fake_input(ev, kc as u8, CURRENT_TIME, self.root, 0, 0, 0);
                    let _ = self.conn.flush();
                }
            }
            InputOp::Text { text } => {
                for ch in text.chars() {
                    if is_cancelled() {
                        break;
                    }
                    let keysym = unicode_to_keysym(ch);
                    if let Some((kc, needs_remap)) = self.pool.acquire(keysym) {
                        if needs_remap {
                            let syms = vec![keysym; self.syms_per_keycode as usize];
                            let _ = self.conn.change_keyboard_mapping(
                                1,
                                kc,
                                self.syms_per_keycode,
                                &syms,
                            );
                            // Synchronize X server via GetInputFocus round-trip (no sleep!).
                            let _ = self.conn.get_input_focus().ok().and_then(|c| c.reply().ok());
                        }
                        let _ = self.conn.xtest_fake_input(KEY_PRESS_EVENT, kc, CURRENT_TIME, self.root, 0, 0, 0);
                        let _ = self.conn.xtest_fake_input(KEY_RELEASE_EVENT, kc, CURRENT_TIME, self.root, 0, 0, 0);
                        let _ = self.conn.flush();
                    }
                }
            }
        }
    }

    pub fn release(&mut self, keys: &[u32], buttons: &[u8]) {
        for &evdev in keys {
            let kc = evdev.saturating_add(8);
            if kc <= 255 {
                let _ = self.conn.xtest_fake_input(
                    KEY_RELEASE_EVENT,
                    kc as u8,
                    CURRENT_TIME,
                    self.root,
                    0,
                    0,
                    0,
                );
            }
        }
        for &btn in buttons {
            let _ = self.conn.xtest_fake_input(
                BUTTON_RELEASE_EVENT,
                Self::x11_button(btn),
                CURRENT_TIME,
                self.root,
                0,
                0,
                0,
            );
        }
        // Restore any remapped spare keycodes back to NoSymbol.
        let zeros = vec![0u32; self.syms_per_keycode as usize];
        for kc in self.pool.dirty_keycodes() {
            let _ = self
                .conn
                .change_keyboard_mapping(1, kc, self.syms_per_keycode, &zeros);
        }
        let _ = self.conn.flush();
    }
}

fn unicode_to_keysym(ch: char) -> u32 {
    match ch {
        '\n' | '\r' => 0xff0d, // Return
        '\t' => 0xff09,        // Tab
        '\x08' => 0xff08,      // BackSpace
        c if (0x20..=0x7e).contains(&(c as u32)) => c as u32,
        c => 0x0100_0000 | (c as u32),
    }
}
