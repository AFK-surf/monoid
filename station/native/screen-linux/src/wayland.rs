// Native Linux Wayland backend (pure Rust via `wayland-client`, `wayland-protocols-wlr`, `wayland-protocols-misc`):
// - Requires `zwlr_screencopy_manager_v1`; returns `WaylandProbe::NoWlr` on compositors without it (e.g. GNOME/KDE)
//   so the station cleanly falls back to XDG Desktop Portal.
// - Capture: `zwlr_screencopy_manager_v1::capture_output` + v3 `copy_with_damage` (v1/v2 `copy`) into a `memfd` `wl_shm` buffer.
// - Input: `zwlr_virtual_pointer_manager_v1` + `zwp_virtual_keyboard_manager_v1` (minimal XKB keymap via `memfd`).

use crate::input_queue::{InputOp, MouseKind};
use std::ffi::CString;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::ptr;
use wayland_client::protocol::{wl_buffer, wl_output, wl_pointer, wl_registry, wl_seat, wl_shm, wl_shm_pool};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1, zwp_virtual_keyboard_v1,
};
use wayland_protocols_wlr::screencopy::v1::client::{
    zwlr_screencopy_frame_v1, zwlr_screencopy_manager_v1,
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1, zwlr_virtual_pointer_v1,
};

pub enum WaylandProbe {
    Ready { width: u32, height: u32 },
    NoWlr(String),
    Unavailable(String),
}

struct Globals {
    output: Option<wl_output::WlOutput>,
    shm: Option<wl_shm::WlShm>,
    seat: Option<wl_seat::WlSeat>,
    screencopy: Option<zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1>,
    screencopy_version: u32,
    vptr_mgr: Option<zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1>,
    vkbd_mgr: Option<zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1>,
    width: u32,
    height: u32,
    // Frame capture state
    buf_format: Option<wl_shm::Format>,
    buf_width: u32,
    buf_height: u32,
    buf_stride: u32,
    buffer_done: bool,
    frame_ready: bool,
    frame_failed: bool,
    y_invert: bool,
}

impl Default for Globals {
    fn default() -> Self {
        Self {
            output: None,
            shm: None,
            seat: None,
            screencopy: None,
            screencopy_version: 0,
            vptr_mgr: None,
            vkbd_mgr: None,
            width: 0,
            height: 0,
            buf_format: None,
            buf_width: 0,
            buf_height: 0,
            buf_stride: 0,
            buffer_done: false,
            frame_ready: false,
            frame_failed: false,
            y_invert: false,
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for Globals {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_output" if state.output.is_none() => {
                    state.output = Some(registry.bind(name, version.min(4), qh, ()));
                }
                "wl_shm" if state.shm.is_none() => {
                    state.shm = Some(registry.bind(name, 1, qh, ()));
                }
                "wl_seat" if state.seat.is_none() => {
                    state.seat = Some(registry.bind(name, version.min(7), qh, ()));
                }
                "zwlr_screencopy_manager_v1" if state.screencopy.is_none() => {
                    let v = version.min(3);
                    state.screencopy = Some(registry.bind(name, v, qh, ()));
                    state.screencopy_version = v;
                }
                "zwlr_virtual_pointer_manager_v1" if state.vptr_mgr.is_none() => {
                    state.vptr_mgr = Some(registry.bind(name, version.min(2), qh, ()));
                }
                "zwp_virtual_keyboard_manager_v1" if state.vkbd_mgr.is_none() => {
                    state.vkbd_mgr = Some(registry.bind(name, 1, qh, ()));
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_output::WlOutput, ()> for Globals {
    fn event(
        state: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_output::Event::Mode { width, height, .. } = event {
            if width > 0 && height > 0 {
                state.width = width as u32;
                state.height = height as u32;
            }
        }
    }
}

impl Dispatch<wl_shm::WlShm, ()> for Globals {
    fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_seat::WlSeat, ()> for Globals {
    fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_shm_pool::WlShmPool, ()> for Globals {
    fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_buffer::WlBuffer, ()> for Globals {
    fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1, ()> for Globals {
    fn event(
        _: &mut Self,
        _: &zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1,
        _: zwlr_screencopy_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zwlr_screencopy_frame_v1::ZwlrScreencopyFrameV1, ()> for Globals {
    fn event(
        state: &mut Self,
        _: &zwlr_screencopy_frame_v1::ZwlrScreencopyFrameV1,
        event: zwlr_screencopy_frame_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_screencopy_frame_v1::Event::Buffer {
                format,
                width,
                height,
                stride,
            } => {
                if let wayland_client::WEnum::Value(fmt) = format {
                    if matches!(
                        fmt,
                        wl_shm::Format::Xrgb8888
                            | wl_shm::Format::Argb8888
                            | wl_shm::Format::Xbgr8888
                            | wl_shm::Format::Abgr8888
                    ) {
                        state.buf_format = Some(fmt);
                        state.buf_width = width;
                        state.buf_height = height;
                        state.buf_stride = stride;
                    }
                }
            }
            zwlr_screencopy_frame_v1::Event::BufferDone => {
                state.buffer_done = true;
            }
            zwlr_screencopy_frame_v1::Event::Flags { flags } => {
                if let wayland_client::WEnum::Value(f) = flags {
                    state.y_invert = f.contains(zwlr_screencopy_frame_v1::Flags::YInvert);
                }
            }
            zwlr_screencopy_frame_v1::Event::Ready { .. } => {
                state.frame_ready = true;
            }
            zwlr_screencopy_frame_v1::Event::Failed => {
                state.frame_failed = true;
            }
            _ => {}
        }
    }
}

impl Dispatch<zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1, ()> for Globals {
    fn event(
        _: &mut Self,
        _: &zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
        _: zwlr_virtual_pointer_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1, ()> for Globals {
    fn event(
        _: &mut Self,
        _: &zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
        _: zwlr_virtual_pointer_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1, ()> for Globals {
    fn event(
        _: &mut Self,
        _: &zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
        _: zwp_virtual_keyboard_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1, ()> for Globals {
    fn event(
        _: &mut Self,
        _: &zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
        _: zwp_virtual_keyboard_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

fn create_memfd(name: &str, size: usize) -> Result<OwnedFd, String> {
    let cname = CString::new(name).unwrap();
    let fd = unsafe { libc::memfd_create(cname.as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err("memfd_create failed".to_string());
    }
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    let rc = unsafe { libc::ftruncate(fd, size as libc::off_t) };
    if rc < 0 {
        return Err("ftruncate memfd failed".to_string());
    }
    Ok(owned)
}

pub fn probe() -> WaylandProbe {
    let conn = match Connection::connect_to_env() {
        Ok(c) => c,
        Err(e) => return WaylandProbe::Unavailable(format!("wayland connect: {e}")),
    };
    let display = conn.display();
    let mut queue = conn.new_event_queue::<Globals>();
    let qh = queue.handle();
    let mut state = Globals::default();
    let _registry = display.get_registry(&qh, ());
    if let Err(e) = queue.roundtrip(&mut state) {
        return WaylandProbe::Unavailable(format!("wayland roundtrip: {e}"));
    }
    if state.screencopy.is_none() {
        return WaylandProbe::NoWlr(
            "compositor does not expose zwlr_screencopy_manager_v1".to_string(),
        );
    }
    if state.output.is_none() || state.shm.is_none() {
        return WaylandProbe::Unavailable("missing wl_output or wl_shm".to_string());
    }
    let _ = queue.roundtrip(&mut state);
    if state.width < 2 || state.height < 2 {
        return WaylandProbe::Unavailable("invalid wayland output dimensions".to_string());
    }
    WaylandProbe::Ready {
        width: state.width,
        height: state.height,
    }
}

struct MmapMem {
    _fd: OwnedFd,
    ptr: *mut u8,
    len: usize,
    pool: wl_shm_pool::WlShmPool,
    buffer: wl_buffer::WlBuffer,
    width: u32,
    height: u32,
    stride: u32,
    format: wl_shm::Format,
}

impl Drop for MmapMem {
    fn drop(&mut self) {
        self.buffer.destroy();
        self.pool.destroy();
        unsafe {
            libc::munmap(self.ptr as *mut libc::c_void, self.len);
        }
    }
}

pub struct WaylandCapture {
    conn: Connection,
    queue: EventQueue<Globals>,
    qh: QueueHandle<Globals>,
    state: Globals,
    mem: Option<MmapMem>,
}

impl WaylandCapture {
    pub fn open() -> Result<Self, String> {
        let conn = Connection::connect_to_env().map_err(|e| format!("wayland connect: {e}"))?;
        let display = conn.display();
        let mut queue = conn.new_event_queue::<Globals>();
        let qh = queue.handle();
        let mut state = Globals::default();
        let _registry = display.get_registry(&qh, ());
        queue
            .roundtrip(&mut state)
            .map_err(|e| format!("wayland roundtrip: {e}"))?;
        if state.screencopy.is_none() {
            return Err("compositor does not expose zwlr_screencopy_manager_v1".to_string());
        }
        if state.output.is_none() || state.shm.is_none() {
            return Err("missing wl_output or wl_shm".to_string());
        }
        queue
            .roundtrip(&mut state)
            .map_err(|e| format!("wayland output roundtrip: {e}"))?;
        if state.width < 2 || state.height < 2 {
            return Err("invalid wayland output dimensions".to_string());
        }
        Ok(Self {
            conn,
            queue,
            qh,
            state,
            mem: None,
        })
    }

    pub fn width(&self) -> u32 {
        self.state.width
    }

    pub fn height(&self) -> u32 {
        self.state.height
    }

    /// Dispatch Wayland events with 25ms `poll()` slices until `done(&state)` is true or `should_abort()` fires.
    /// Returns `Ok(true)` when `done` is satisfied, `Ok(false)` when aborted early.
    fn dispatch_until(
        &mut self,
        done: impl Fn(&Globals) -> bool,
        should_abort: &dyn Fn() -> bool,
    ) -> Result<bool, String> {
        self.queue
            .dispatch_pending(&mut self.state)
            .map_err(|e| format!("wayland dispatch: {e}"))?;
        while !done(&self.state) {
            if should_abort() {
                return Ok(false);
            }
            let _ = self.conn.flush();
            if let Some(guard) = self.queue.prepare_read() {
                let fd = guard.connection_fd().as_raw_fd();
                let mut pfd = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                let rc = unsafe { libc::poll(&mut pfd, 1, 25) };
                if rc > 0 && (pfd.revents & libc::POLLIN) != 0 {
                    let _ = guard.read();
                } else {
                    drop(guard);
                }
            }
            self.queue
                .dispatch_pending(&mut self.state)
                .map_err(|e| format!("wayland dispatch: {e}"))?;
        }
        Ok(true)
    }

    /// Capture one frame into `out_bgra`. Returns `Ok(true)` when a frame was captured,
    /// or `Ok(false)` if aborted early by `should_abort` (e.g. stdin close / keyframe / bounds).
    pub fn capture_bgra(
        &mut self,
        out_bgra: &mut Vec<u8>,
        with_damage: bool,
        overlay_cursor: bool,
        should_abort: &dyn Fn() -> bool,
    ) -> Result<bool, String> {
        let mgr = self
            .state
            .screencopy
            .as_ref()
            .ok_or_else(|| "no screencopy manager".to_string())?
            .clone();
        let output = self
            .state
            .output
            .as_ref()
            .ok_or_else(|| "no wl_output".to_string())?
            .clone();
        let shm = self
            .state
            .shm
            .as_ref()
            .ok_or_else(|| "no wl_shm".to_string())?
            .clone();

        self.state.buf_format = None;
        self.state.buffer_done = false;
        self.state.frame_ready = false;
        self.state.frame_failed = false;
        self.state.y_invert = false;

        let frame = mgr.capture_output(if overlay_cursor { 1 } else { 0 }, &output, &self.qh, ());
        let v3 = self.state.screencopy_version >= 3;
        let got_buf = self.dispatch_until(
            |s| s.frame_failed || if v3 { s.buffer_done } else { s.buf_format.is_some() },
            should_abort,
        )?;
        if !got_buf {
            frame.destroy();
            let _ = self.conn.flush();
            return Ok(false);
        }
        if self.state.frame_failed {
            frame.destroy();
            return Err("wlr-screencopy frame failed".to_string());
        }

        let fmt = self
            .state
            .buf_format
            .ok_or_else(|| "unsupported wl_shm format".to_string())?;
        let bw = self.state.buf_width;
        let bh = self.state.buf_height;
        let stride = self.state.buf_stride;
        let byte_len = (stride as usize) * (bh as usize);

        let need_alloc = match self.mem {
            Some(ref m) => m.width != bw || m.height != bh || m.stride != stride || m.format != fmt,
            None => true,
        };
        if need_alloc {
            let fd = create_memfd("stillfail-wl-shm", byte_len)?;
            let ptr = unsafe {
                libc::mmap(
                    ptr::null_mut(),
                    byte_len,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_SHARED,
                    fd.as_raw_fd(),
                    0,
                )
            };
            if ptr == libc::MAP_FAILED {
                frame.destroy();
                return Err("mmap wl_shm failed".to_string());
            }
            let pool = shm.create_pool(fd.as_fd(), byte_len as i32, &self.qh, ());
            let buffer = pool.create_buffer(0, bw as i32, bh as i32, stride as i32, fmt, &self.qh, ());
            self.mem = Some(MmapMem {
                _fd: fd,
                ptr: ptr as *mut u8,
                len: byte_len,
                pool,
                buffer,
                width: bw,
                height: bh,
                stride,
                format: fmt,
            });
        }

        let mem = self.mem.as_ref().unwrap();
        if with_damage && self.state.screencopy_version >= 3 {
            frame.copy_with_damage(&mem.buffer);
        } else {
            frame.copy(&mem.buffer);
        }

        let got_frame = self.dispatch_until(|s| s.frame_ready || s.frame_failed, should_abort)?;
        frame.destroy();
        let _ = self.conn.flush();
        if !got_frame {
            return Ok(false);
        }

        if self.state.frame_failed {
            return Err("wlr-screencopy copy failed".to_string());
        }

        let mem = self.mem.as_ref().unwrap();
        let raw = unsafe { std::slice::from_raw_parts(mem.ptr, mem.len) };
        let w = bw as usize;
        let h = bh as usize;
        let s = stride as usize;
        out_bgra.resize(w * h * 4, 255);
        let swap_rb = matches!(fmt, wl_shm::Format::Xbgr8888 | wl_shm::Format::Abgr8888);
        for row in 0..h {
            let src_row = if self.state.y_invert { h - 1 - row } else { row } * s;
            let dst_row = row * w * 4;
            if !swap_rb {
                out_bgra[dst_row..dst_row + w * 4].copy_from_slice(&raw[src_row..src_row + w * 4]);
            } else {
                for col in 0..w {
                    let sp = src_row + col * 4;
                    let dp = dst_row + col * 4;
                    out_bgra[dp] = raw[sp + 2];
                    out_bgra[dp + 1] = raw[sp + 1];
                    out_bgra[dp + 2] = raw[sp];
                    out_bgra[dp + 3] = 255;
                }
            }
        }
        Ok(true)
    }
}

/// Minimal XKB US keymap uploaded to `zwp_virtual_keyboard_v1` via memfd.
const MINIMAL_XKB_KEYMAP: &str = r#"xkb_keymap {
  xkb_keycodes "(unnamed)" {
    minimum = 8;
    maximum = 255;
    <ESC> = 9; <AE01> = 10; <AE02> = 11; <AE03> = 12; <AE04> = 13; <AE05> = 14;
    <AE06> = 15; <AE07> = 16; <AE08> = 17; <AE09> = 18; <AE10> = 19; <AE11> = 20;
    <AE12> = 21; <BKSP> = 22; <TAB> = 23; <AD01> = 24; <AD02> = 25; <AD03> = 26;
    <AD04> = 27; <AD05> = 28; <AD06> = 29; <AD07> = 30; <AD08> = 31; <AD09> = 32;
    <AD10> = 33; <AD11> = 34; <AD12> = 35; <RTRN> = 36; <LCTL> = 37; <AC01> = 38;
    <AC02> = 39; <AC03> = 40; <AC04> = 41; <AC05> = 42; <AC06> = 43; <AC07> = 44;
    <AC08> = 45; <AC09> = 46; <AC10> = 47; <AC11> = 48; <TLDE> = 49; <LFSH> = 50;
    <BKSL> = 51; <AB01> = 52; <AB02> = 53; <AB03> = 54; <AB04> = 55; <AB05> = 56;
    <AB06> = 57; <AB07> = 58; <AB08> = 59; <AB09> = 60; <AB10> = 61; <RTSH> = 62;
    <LALT> = 64; <SPCE> = 65; <LWIN> = 133; <RWIN> = 134;
    <UP> = 111; <LEFT> = 113; <RGHT> = 114; <DOWN> = 116;
  };
  xkb_types "(unnamed)" {
    virtual_modifiers NumLock,Alt,LevelThree;
    type "ONE_LEVEL" { modifiers= none; };
    type "TWO_LEVEL" { modifiers= Shift; map[Shift]= Level2; };
    type "ALPHABETIC" { modifiers= Shift+Lock; map[Shift]= Level2; map[Lock]= Level2; };
  };
  xkb_compatibility "(unnamed)" { interpret Any+AnyOf(all) { action= SetMods(modifiers=modMapMods,clearLocks); }; };
  xkb_symbols "(unnamed)" {
    key <ESC> { [ Escape ] };
    key <AE01> { [ 1, exclam ] }; key <AE02> { [ 2, at ] }; key <AE03> { [ 3, numbersign ] };
    key <AE04> { [ 4, dollar ] }; key <AE05> { [ 5, percent ] }; key <AE06> { [ 6, asciicircum ] };
    key <AE07> { [ 7, ampersand ] }; key <AE08> { [ 8, asterisk ] }; key <AE09> { [ 9, parenleft ] };
    key <AE10> { [ 0, parenright ] }; key <AE11> { [ minus, underscore ] }; key <AE12> { [ equal, plus ] };
    key <BKSP> { [ BackSpace ] }; key <TAB> { [ Tab ] }; key <RTRN> { [ Return ] };
    key <AD01> { [ q, Q ] }; key <AD02> { [ w, W ] }; key <AD03> { [ e, E ] }; key <AD04> { [ r, R ] };
    key <AD05> { [ t, T ] }; key <AD06> { [ y, Y ] }; key <AD07> { [ u, U ] }; key <AD08> { [ i, I ] };
    key <AD09> { [ o, O ] }; key <AD10> { [ p, P ] }; key <AD11> { [ bracketleft, braceleft ] };
    key <AD12> { [ bracketright, braceright ] };
    key <AC01> { [ a, A ] }; key <AC02> { [ s, S ] }; key <AC03> { [ d, D ] }; key <AC04> { [ f, F ] };
    key <AC05> { [ g, G ] }; key <AC06> { [ h, H ] }; key <AC07> { [ j, J ] }; key <AC08> { [ k, K ] };
    key <AC09> { [ l, L ] }; key <AC10> { [ semicolon, colon ] }; key <AC11> { [ apostrophe, quotedbl ] };
    key <TLDE> { [ grave, asciitilde ] }; key <BKSL> { [ backslash, bar ] };
    key <AB01> { [ z, Z ] }; key <AB02> { [ x, X ] }; key <AB03> { [ c, C ] }; key <AB04> { [ v, V ] };
    key <AB05> { [ b, B ] }; key <AB06> { [ n, N ] }; key <AB07> { [ m, M ] }; key <AB08> { [ comma, less ] };
    key <AB09> { [ period, greater ] }; key <AB10> { [ slash, question ] };
    key <SPCE> { [ space ] };
    key <LCTL> { [ Control_L ] }; key <LFSH> { [ Shift_L ] }; key <RTSH> { [ Shift_R ] };
    key <LALT> { [ Alt_L ] }; key <LWIN> { [ Super_L ] }; key <RWIN> { [ Super_R ] };
    key <UP> { [ Up ] }; key <DOWN> { [ Down ] }; key <LEFT> { [ Left ] }; key <RGHT> { [ Right ] };
    modifier_map Control { <LCTL> };
    modifier_map Shift { <LFSH>, <RTSH> };
    modifier_map Mod1 { <LALT> };
    modifier_map Mod4 { <LWIN>, <RWIN> };
  };
};
"#;

pub struct WaylandInputDriver {
    conn: Connection,
    _queue: EventQueue<Globals>,
    vptr: Option<zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1>,
    vkbd: Option<zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1>,
    width: u32,
    height: u32,
    time_ms: u32,
}

impl WaylandInputDriver {
    pub fn open(width: u32, height: u32) -> Result<Self, String> {
        let conn = Connection::connect_to_env().map_err(|e| format!("wayland input connect: {e}"))?;
        let display = conn.display();
        let mut queue = conn.new_event_queue::<Globals>();
        let qh = queue.handle();
        let mut state = Globals::default();
        let _registry = display.get_registry(&qh, ());
        queue
            .roundtrip(&mut state)
            .map_err(|e| format!("wayland input roundtrip: {e}"))?;

        let vptr = state
            .vptr_mgr
            .as_ref()
            .map(|mgr| mgr.create_virtual_pointer(state.seat.as_ref(), &qh, ()));
        let vkbd = match (state.vkbd_mgr.as_ref(), state.seat.as_ref()) {
            (Some(mgr), Some(seat)) => {
                let kbd = mgr.create_virtual_keyboard(seat, &qh, ());
                let bytes = MINIMAL_XKB_KEYMAP.as_bytes();
                if let Ok(fd) = create_memfd("stillfail-xkb", bytes.len() + 1) {
                    unsafe {
                        let _ = libc::write(
                            std::os::fd::AsRawFd::as_raw_fd(&fd),
                            bytes.as_ptr().cast(),
                            bytes.len(),
                        );
                    }
                    kbd.keymap(1, fd.as_fd(), (bytes.len() + 1) as u32);
                }
                Some(kbd)
            }
            _ => None,
        };
        let _ = conn.flush();
        Ok(Self {
            conn,
            _queue: queue,
            vptr,
            vkbd,
            width: width.max(1),
            height: height.max(1),
            time_ms: 1,
        })
    }

    fn linux_button(button: u8) -> u32 {
        match button {
            0 => 0x110, // BTN_LEFT
            1 => 0x112, // BTN_MIDDLE
            2 => 0x111, // BTN_RIGHT
            _ => 0x110,
        }
    }

    pub fn apply(&mut self, op: &InputOp) {
        self.time_ms = self.time_ms.wrapping_add(1);
        match op {
            InputOp::Mouse {
                kind,
                x,
                y,
                button,
                dx,
                dy,
                relative,
            } => {
                if let Some(ref ptr) = self.vptr {
                    match kind {
                        MouseKind::Move => {
                            if *relative {
                                ptr.motion(self.time_ms, dx.unwrap_or(0.0), dy.unwrap_or(0.0));
                            } else {
                                let px = (x.clamp(0.0, 1.0) * (self.width as f64)).round() as u32;
                                let py = (y.clamp(0.0, 1.0) * (self.height as f64)).round() as u32;
                                ptr.motion_absolute(self.time_ms, px, py, self.width, self.height);
                            }
                            ptr.frame();
                        }
                        MouseKind::Down | MouseKind::Up => {
                            if !*relative {
                                let px = (x.clamp(0.0, 1.0) * (self.width as f64)).round() as u32;
                                let py = (y.clamp(0.0, 1.0) * (self.height as f64)).round() as u32;
                                ptr.motion_absolute(self.time_ms, px, py, self.width, self.height);
                            }
                            let state = if matches!(kind, MouseKind::Down) {
                                wl_pointer::ButtonState::Pressed
                            } else {
                                wl_pointer::ButtonState::Released
                            };
                            ptr.button(self.time_ms, Self::linux_button(*button), state);
                            ptr.frame();
                        }
                    }
                    let _ = self.conn.flush();
                }
            }
            InputOp::Wheel { x, y, dx, dy } => {
                if let Some(ref ptr) = self.vptr {
                    if *x >= 0.0 && *y >= 0.0 {
                        let px = (x.clamp(0.0, 1.0) * (self.width as f64)).round() as u32;
                        let py = (y.clamp(0.0, 1.0) * (self.height as f64)).round() as u32;
                        ptr.motion_absolute(self.time_ms, px, py, self.width, self.height);
                    }
                    if *dy != 0.0 {
                        ptr.axis(self.time_ms, wl_pointer::Axis::VerticalScroll, *dy * 15.0);
                    }
                    if *dx != 0.0 {
                        ptr.axis(self.time_ms, wl_pointer::Axis::HorizontalScroll, *dx * 15.0);
                    }
                    ptr.frame();
                    let _ = self.conn.flush();
                }
            }
            InputOp::Key { evdev, down } => {
                if let Some(ref kbd) = self.vkbd {
                    kbd.key(self.time_ms, *evdev, if *down { 1 } else { 0 });
                    let _ = self.conn.flush();
                }
            }
            InputOp::Text { .. } => {
                // Virtual keyboard operates on evdev keycodes; ASCII/Unicode text typing is handled
                // by key events from the client or portal fallback when needed.
            }
        }
    }

    pub fn release(&mut self, keys: &[u32], buttons: &[u8]) {
        if let Some(ref kbd) = self.vkbd {
            for &evdev in keys {
                self.time_ms = self.time_ms.wrapping_add(1);
                kbd.key(self.time_ms, evdev, 0);
            }
        }
        if let Some(ref ptr) = self.vptr {
            for &btn in buttons {
                self.time_ms = self.time_ms.wrapping_add(1);
                ptr.button(
                    self.time_ms,
                    Self::linux_button(btn),
                    wl_pointer::ButtonState::Released,
                );
            }
            ptr.frame();
        }
        let _ = self.conn.flush();
    }
}
