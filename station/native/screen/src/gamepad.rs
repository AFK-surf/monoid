// A person's game controllers on this machine (`{op: "gamepad"}`, station/src/screens/win-input.ts): a virtual Xbox
// 360 controller each (XInput's, which every game reads) where ViGEmBus is installed, spoken to directly through
// Windows' SetupDi device interface and DeviceIoControl (no external ViGEmClient.dll needed: the ViGEmBus driver
// installer does not install ViGEmClient.dll into System32). When the user explicitly enables desktop mouse/keyboard
// emulation (`gamepadMouse` / `{op: "gamepadMode", mouse: true}`), controllers drive the desktop as
// station/src/screens/gamepad-desktop.ts maps one; when off (the default), controllers never silently fall back to
// moving the mouse when ViGEmBus is missing. A controller let go of (`connected: false`, mode switch, the view's end)
// lets go of all it holds.
use serde_json::Value;

/// ViGEmBus device interface GUID `{96E42B22-F5E9-42F8-B043-ED0F932F014F}`.
pub const VIGEM_GUID_DATA1: u32 = 0x96E4_2B22;
pub const VIGEM_GUID_DATA2: u16 = 0xF5E9;
pub const VIGEM_GUID_DATA3: u16 = 0x42F8;
pub const VIGEM_GUID_DATA4: [u8; 8] = [0xB0, 0x43, 0xED, 0x0F, 0x93, 0x2F, 0x01, 0x4F];

/// ViGEmBus IOCTL protocol constants (`ViGEmBusShared.h`, MIT license).
pub const FILE_DEVICE_BUS_EXTENDER: u32 = 0x0000_002A;
pub const METHOD_BUFFERED: u32 = 0;
pub const FILE_WRITE_DATA: u32 = 0x0002;
pub const IOCTL_VIGEM_BASE: u32 = 0x801;
pub const VIGEM_COMMON_VERSION: u32 = 0x0001;
pub const VIGEM_TARGET_XBOX360_WIRED: u32 = 0;
pub const X360_VENDOR_ID: u16 = 0x045E;
pub const X360_PRODUCT_ID: u16 = 0x028E;
pub const VIGEM_TARGETS_MAX: u32 = 255;

pub const fn ctl_code(device_type: u32, function: u32, method: u32, access: u32) -> u32 {
    (device_type << 16) | (access << 14) | (function << 2) | method
}

pub const IOCTL_VIGEM_PLUGIN_TARGET: u32 = ctl_code(FILE_DEVICE_BUS_EXTENDER, IOCTL_VIGEM_BASE, METHOD_BUFFERED, FILE_WRITE_DATA);
pub const IOCTL_VIGEM_UNPLUG_TARGET: u32 = ctl_code(FILE_DEVICE_BUS_EXTENDER, IOCTL_VIGEM_BASE + 0x001, METHOD_BUFFERED, FILE_WRITE_DATA);
pub const IOCTL_VIGEM_CHECK_VERSION: u32 = ctl_code(FILE_DEVICE_BUS_EXTENDER, IOCTL_VIGEM_BASE + 0x002, METHOD_BUFFERED, FILE_WRITE_DATA);
pub const IOCTL_VIGEM_WAIT_DEVICE_READY: u32 = ctl_code(FILE_DEVICE_BUS_EXTENDER, IOCTL_VIGEM_BASE + 0x003, METHOD_BUFFERED, FILE_WRITE_DATA);
pub const IOCTL_XUSB_SUBMIT_REPORT: u32 = ctl_code(FILE_DEVICE_BUS_EXTENDER, IOCTL_VIGEM_BASE + 0x201, METHOD_BUFFERED, FILE_WRITE_DATA);

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct VigemCheckVersion {
    pub size: u32,
    pub version: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct VigemPluginTarget {
    pub size: u32,
    pub serial_no: u32,
    pub target_type: u32,
    pub vendor_id: u16,
    pub product_id: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct VigemSerial {
    pub size: u32,
    pub serial_no: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct XusbSubmitReport {
    pub size: u32,
    pub serial_no: u32,
    pub report: Report,
}

/// One controller's state as the station says it (the W3C Standard Gamepad's).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Pad {
    pub buttons: u32,
    pub lx: f64,
    pub ly: f64,
    pub rx: f64,
    pub ry: f64,
    pub lt: f64,
    pub rt: f64,
}

pub const DEAD_ZONE: f64 = 0.15;
pub const TRIGGER_DOWN: f64 = 0.5;
/// Pixels a second at a stick's full travel (its travel squared), and the wheel's units (120 a notch) a second.
pub const POINTER_SPEED: f64 = 1500.0;
pub const WHEEL_SPEED: f64 = 2400.0;
pub const TICK_MS: u64 = 16;

/// The W3C buttons' bits.
pub mod bit {
    pub const A: u32 = 0;
    pub const B: u32 = 1;
    pub const X: u32 = 2;
    pub const Y: u32 = 3;
    pub const LB: u32 = 4;
    pub const RB: u32 = 5;
    pub const LT: u32 = 6;
    pub const RT: u32 = 7;
    pub const BACK: u32 = 8;
    pub const START: u32 = 9;
    pub const LS: u32 = 10;
    pub const RS: u32 = 11;
    pub const UP: u32 = 12;
    pub const DOWN: u32 = 13;
    pub const LEFT: u32 = 14;
    pub const RIGHT: u32 = 15;
    pub const HOME: u32 = 16;
}

/// An op's slot and state: None not one; Some((index, None)) a controller let go of.
pub fn of(op: &Value) -> Option<(usize, Option<Pad>)> {
    let index = op["index"].as_u64().filter(|&i| i < 4)? as usize;
    if op["connected"].as_bool() == Some(false) {
        return Some((index, None));
    }
    let n = |k: &str, lo: f64| op[k].as_f64().filter(|v| v.is_finite()).unwrap_or(0.0).clamp(lo, 1.0);
    Some((index, Some(Pad { buttons: op["buttons"].as_u64().unwrap_or(0) as u32 & 0x1ffff, lx: n("lx", -1.0), ly: n("ly", -1.0), rx: n("rx", -1.0), ry: n("ry", -1.0), lt: n("lt", 0.0), rt: n("rt", 0.0) })))
}

impl Pad {
    /// The buttons held, the triggers pressed past half way as two more.
    pub fn held(&self) -> u32 {
        let triggers = (1 << bit::LT) | (1 << bit::RT);
        (self.buttons & !triggers) | if self.lt > TRIGGER_DOWN { 1 << bit::LT } else { 0 } | if self.rt > TRIGGER_DOWN { 1 << bit::RT } else { 0 }
    }

    pub fn moving(&self) -> bool {
        [self.lx, self.ly, self.rx, self.ry].iter().any(|&v| past(v) != 0.0)
    }
}

/// A stick's travel past its dead zone, 0..1 again, its sign kept.
pub fn past(v: f64) -> f64 {
    let a = v.abs();
    if a <= DEAD_ZONE { 0.0 } else { v.signum() * (a - DEAD_ZONE) / (1.0 - DEAD_ZONE) }
}

/// How far a tick of `ms` moves the pointer (pixels) and the wheels (their units: positive up and right, Windows').
pub fn step(p: &Pad, ms: f64) -> (f64, f64, f64, f64) {
    let sq = |v: f64| {
        let q = past(v);
        q * q.abs()
    };
    let s = ms / 1000.0;
    (sq(p.lx) * POINTER_SPEED * s, sq(p.ly) * POINTER_SPEED * s, past(p.rx) * WHEEL_SPEED * s, -past(p.ry) * WHEEL_SPEED * s)
}

/// XInput's report of a state (XUSB_REPORT): its buttons, its triggers 0..255, its sticks (up positive, as XInput has
/// them, where the W3C's are down positive).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Report {
    pub buttons: u16,
    pub left_trigger: u8,
    pub right_trigger: u8,
    pub lx: i16,
    pub ly: i16,
    pub rx: i16,
    pub ry: i16,
}

pub fn report(p: &Pad) -> Report {
    const MAP: [(u32, u16); 15] = [
        (bit::UP, 0x0001), (bit::DOWN, 0x0002), (bit::LEFT, 0x0004), (bit::RIGHT, 0x0008), (bit::START, 0x0010), (bit::BACK, 0x0020),
        (bit::LS, 0x0040), (bit::RS, 0x0080), (bit::LB, 0x0100), (bit::RB, 0x0200), (bit::HOME, 0x0400), (bit::A, 0x1000),
        (bit::B, 0x2000), (bit::X, 0x4000), (bit::Y, 0x8000),
    ];
    let buttons = MAP.iter().filter(|(b, _)| p.buttons & (1 << b) != 0).fold(0u16, |a, (_, x)| a | x);
    let stick = |v: f64| if v >= 0.0 { (v * 32767.0).round() as i16 } else { (v * 32768.0).round().max(-32768.0) as i16 };
    let trigger = |v: f64, held: bool| ((if held { v.max(1.0) } else { v }) * 255.0).round().clamp(0.0, 255.0) as u8;
    Report {
        buttons,
        left_trigger: trigger(p.lt, p.buttons & (1 << bit::LT) != 0),
        right_trigger: trigger(p.rt, p.buttons & (1 << bit::RT) != 0),
        lx: stick(p.lx),
        ly: stick(-p.ly),
        rx: stick(p.rx),
        ry: stick(-p.ry),
    }
}

/// What a button drives on the desktop: a mouse button (1 left, 2 right), or a key by its scan code (`ext`: an E0
/// key) with Shift round it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Does {
    Mouse(u8),
    Key { scan: u16, ext: bool, shift: bool },
}

pub fn does(b: u32) -> Option<Does> {
    let key = |scan, ext, shift| Some(Does::Key { scan, ext, shift });
    match b {
        bit::A => Some(Does::Mouse(1)),
        bit::B => Some(Does::Mouse(2)),
        bit::X => key(0x01, false, false),
        bit::Y => key(0x1c, false, false),
        bit::LB => key(0x0f, false, true),
        bit::RB => key(0x0f, false, false),
        bit::LT => key(0x49, true, false),
        bit::RT => key(0x51, true, false),
        bit::BACK => key(0x0e, false, false),
        bit::START => key(0x39, false, false),
        bit::UP => key(0x48, true, false),
        bit::DOWN => key(0x50, true, false),
        bit::LEFT => key(0x4b, true, false),
        bit::RIGHT => key(0x4d, true, false),
        _ => None,
    }
}

/// The buttons a change of what is held presses (true) and lets go of.
pub fn changes(was: u32, now: u32) -> Vec<(u32, bool)> {
    (0..17).filter(|b| (was ^ now) & (1 << b) != 0).map(|b| (b, now & (1 << b) != 0)).collect()
}

#[cfg(windows)]
pub use pads::Gamepads;

#[cfg(windows)]
mod pads {
    use std::ffi::c_void;
    use std::mem::size_of;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use serde_json::Value;
    use windows::Win32::Devices::DeviceAndDriverInstallation::{
        DIGCF_DEVICEINTERFACE, DIGCF_PRESENT, SP_DEVICE_INTERFACE_DATA, SP_DEVICE_INTERFACE_DETAIL_DATA_W,
        SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInterfaces, SetupDiGetClassDevsW, SetupDiGetDeviceInterfaceDetailW,
    };
    use windows::Win32::Foundation::{
        CloseHandle, ERROR_INVALID_PARAMETER, ERROR_IO_PENDING, GENERIC_READ, GENERIC_WRITE, GetLastError, HANDLE,
        INVALID_HANDLE_VALUE,
    };
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_NO_BUFFERING, FILE_FLAG_OVERLAPPED, FILE_FLAG_WRITE_THROUGH,
        FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    use windows::Win32::System::IO::{DeviceIoControl, GetOverlappedResult, OVERLAPPED};
    use windows::Win32::System::Threading::CreateEventW;
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    use windows::core::{GUID, PCWSTR};

    use super::{
        Does, IOCTL_VIGEM_CHECK_VERSION, IOCTL_VIGEM_PLUGIN_TARGET, IOCTL_VIGEM_UNPLUG_TARGET,
        IOCTL_VIGEM_WAIT_DEVICE_READY, IOCTL_XUSB_SUBMIT_REPORT, Pad, Report, TICK_MS, VIGEM_COMMON_VERSION,
        VIGEM_GUID_DATA1, VIGEM_GUID_DATA2, VIGEM_GUID_DATA3, VIGEM_GUID_DATA4, VIGEM_TARGET_XBOX360_WIRED,
        VIGEM_TARGETS_MAX, VigemCheckVersion, VigemPluginTarget, VigemSerial, X360_PRODUCT_ID, X360_VENDOR_ID,
        XusbSubmitReport, changes, does, of, report, step,
    };
    use crate::Out;
    use crate::mouse::Carry;

    /// Direct kernel-driver handle to ViGEmBus (`ViGEmBus.sys`), no `ViGEmClient.dll` required.
    struct Vigem {
        handle: HANDLE,
    }

    // (ViGEmBus handle is used from one thread at a time, behind the state's lock)
    unsafe impl Send for Vigem {}

    fn ioctl<T>(handle: HANDLE, code: u32, input: &T) -> Result<(), u32> {
        unsafe {
            let event = CreateEventW(None, false, false, None).map_err(|e| e.code().0 as u32)?;
            let mut overlapped = OVERLAPPED { hEvent: event, ..Default::default() };
            let mut transferred = 0u32;
            let res = DeviceIoControl(
                handle,
                code,
                Some(input as *const T as *const c_void),
                size_of::<T>() as u32,
                None,
                0,
                Some(&mut transferred),
                Some(&mut overlapped),
            );
            let out = if res.is_ok() {
                Ok(())
            } else {
                let err = GetLastError();
                if err == ERROR_IO_PENDING {
                    if GetOverlappedResult(handle, &overlapped, &mut transferred, true).is_ok() {
                        Ok(())
                    } else {
                        Err(GetLastError().0)
                    }
                } else {
                    Err(err.0)
                }
            };
            let _ = CloseHandle(event);
            out
        }
    }

    impl Vigem {
        fn connect() -> Option<Vigem> {
            let guid = GUID::from_values(VIGEM_GUID_DATA1, VIGEM_GUID_DATA2, VIGEM_GUID_DATA3, VIGEM_GUID_DATA4);
            unsafe {
                let info = SetupDiGetClassDevsW(Some(&guid), None, None, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE).ok()?;
                let mut found: Option<Vigem> = None;
                let mut member = 0u32;
                loop {
                    let mut iface = SP_DEVICE_INTERFACE_DATA {
                        cbSize: size_of::<SP_DEVICE_INTERFACE_DATA>() as u32,
                        ..Default::default()
                    };
                    if SetupDiEnumDeviceInterfaces(info, None, &guid, member, &mut iface).is_err() {
                        break;
                    }
                    member += 1;
                    let mut required = 0u32;
                    let _ = SetupDiGetDeviceInterfaceDetailW(info, &iface, None, 0, Some(&mut required), None);
                    if (required as usize) < size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() {
                        continue;
                    }
                    let mut buf = vec![0u32; (required as usize + 3) / 4];
                    let detail = buf.as_mut_ptr() as *mut SP_DEVICE_INTERFACE_DETAIL_DATA_W;
                    (*detail).cbSize = size_of::<SP_DEVICE_INTERFACE_DETAIL_DATA_W>() as u32;
                    if SetupDiGetDeviceInterfaceDetailW(info, &iface, Some(detail), required, None, None).is_err() {
                        continue;
                    }
                    let path = PCWSTR((*detail).DevicePath.as_ptr());
                    let Ok(handle) = CreateFileW(
                        path,
                        GENERIC_READ.0 | GENERIC_WRITE.0,
                        FILE_SHARE_READ | FILE_SHARE_WRITE,
                        None,
                        OPEN_EXISTING,
                        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED,
                        None,
                    ) else {
                        continue;
                    };
                    if handle == INVALID_HANDLE_VALUE {
                        continue;
                    }
                    let check = VigemCheckVersion { size: size_of::<VigemCheckVersion>() as u32, version: VIGEM_COMMON_VERSION };
                    if ioctl(handle, IOCTL_VIGEM_CHECK_VERSION, &check).is_ok() {
                        found = Some(Vigem { handle });
                        break;
                    }
                    let _ = CloseHandle(handle);
                }
                let _ = SetupDiDestroyDeviceInfoList(info);
                found
            }
        }

        fn add(&self) -> Option<u32> {
            for serial_no in 1..=VIGEM_TARGETS_MAX {
                let plugin = VigemPluginTarget {
                    size: size_of::<VigemPluginTarget>() as u32,
                    serial_no,
                    target_type: VIGEM_TARGET_XBOX360_WIRED,
                    vendor_id: X360_VENDOR_ID,
                    product_id: X360_PRODUCT_ID,
                };
                if ioctl(self.handle, IOCTL_VIGEM_PLUGIN_TARGET, &plugin).is_err() {
                    continue;
                }
                let wait = VigemSerial { size: size_of::<VigemSerial>() as u32, serial_no };
                match ioctl(self.handle, IOCTL_VIGEM_WAIT_DEVICE_READY, &wait) {
                    Ok(()) => return Some(serial_no),
                    // Pre-v1.17 ViGEmBus has no WAIT_DEVICE_READY IOCTL; target is already operational.
                    Err(code) if code == ERROR_INVALID_PARAMETER.0 => return Some(serial_no),
                    Err(_) => {
                        let _ = ioctl(self.handle, IOCTL_VIGEM_UNPLUG_TARGET, &wait);
                        return None;
                    }
                }
            }
            None
        }

        fn update(&self, serial_no: u32, report: Report) {
            let submit = XusbSubmitReport { size: size_of::<XusbSubmitReport>() as u32, serial_no, report };
            let _ = ioctl(self.handle, IOCTL_XUSB_SUBMIT_REPORT, &submit);
        }

        fn remove(&self, serial_no: u32) {
            self.update(serial_no, Report::default());
            let unplug = VigemSerial { size: size_of::<VigemSerial>() as u32, serial_no };
            let _ = ioctl(self.handle, IOCTL_VIGEM_UNPLUG_TARGET, &unplug);
        }
    }

    impl Drop for Vigem {
        fn drop(&mut self) {
            if !self.handle.is_invalid() {
                unsafe {
                    let _ = CloseHandle(self.handle);
                }
            }
        }
    }

    struct State {
        pads: [Option<Pad>; 4],
        /// Where ViGEmBus is: each slot's virtual Xbox 360 serial number.
        vigem: Option<Vigem>,
        targets: [Option<u32>; 4],
        /// Explicit opt-in for desktop mouse/keyboard emulation (false by default: never silently hijack mouse).
        allow_mouse: bool,
        /// The mouse buttons the desktop's controllers hold (1 left, 2 right), and the parts of a pixel and of a
        /// wheel's unit not posted yet.
        mouse: u8,
        carry: (Carry, Carry, f64, f64),
    }

    unsafe impl Send for State {}

    pub struct Gamepads {
        out: Out,
        state: Arc<Mutex<State>>,
        ticking: Arc<AtomicBool>,
        moved: Arc<dyn Fn() + Send + Sync>,
    }

    fn send(inputs: &[INPUT]) {
        if !inputs.is_empty() {
            unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
        }
    }

    fn mouse(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
        INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
    }

    fn key(scan: u16, ext: bool, down: bool) -> INPUT {
        let flags = KEYEVENTF_SCANCODE | if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP } | if ext { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
        INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
    }

    fn emit_status(out: &Out, has_vigem: bool, allow_mouse: bool) {
        out.json(
            4,
            serde_json::json!({
                "gamepad": {
                    "native": has_vigem,
                    "driver": if has_vigem { "vigembus" } else { "missing" },
                    "mouse": allow_mouse,
                }
            }),
        );
    }

    fn release_desktop(state: &mut State) {
        for index in 0..4 {
            let Some(was) = state.pads[index].take() else { continue };
            for (b, down) in changes(was.held(), 0) {
                match does(b) {
                    Some(Does::Mouse(m)) => {
                        let held_before = state.mouse;
                        if down { state.mouse |= m } else { state.mouse &= !m }
                        if held_before != state.mouse {
                            let flags = match (m, down) {
                                (1, true) => MOUSEEVENTF_LEFTDOWN,
                                (1, false) => MOUSEEVENTF_LEFTUP,
                                (_, true) => MOUSEEVENTF_RIGHTDOWN,
                                (_, false) => MOUSEEVENTF_RIGHTUP,
                            };
                            send(&[mouse(0, 0, 0, flags)]);
                        }
                    }
                    Some(Does::Key { scan, ext, .. }) => send(&[key(scan, ext, false)]),
                    None => {}
                }
            }
        }
        state.mouse = 0;
        state.carry = (Carry::default(), Carry::default(), 0.0, 0.0);
    }

    fn release_vigem(state: &mut State) {
        if let Some(vigem) = state.vigem.as_ref() {
            for target in &mut state.targets {
                if let Some(serial) = target.take() {
                    vigem.remove(serial);
                }
            }
        }
        state.pads = [None; 4];
    }

    impl Gamepads {
        /// `moved`: told of each move it posts (pointer_lock.rs's moves).
        pub fn new(out: &Out, allow_mouse: bool, moved: impl Fn() + Send + Sync + 'static) -> Gamepads {
            let vigem = Vigem::connect();
            emit_status(out, vigem.is_some(), allow_mouse);
            Gamepads {
                out: out.clone(),
                state: Arc::new(Mutex::new(State {
                    pads: [None; 4],
                    vigem,
                    targets: [None; 4],
                    allow_mouse,
                    mouse: 0,
                    carry: (Carry::default(), Carry::default(), 0.0, 0.0),
                })),
                ticking: Arc::new(AtomicBool::new(false)),
                moved: Arc::new(moved),
            }
        }

        /// Switch between native virtual controller mode and explicit mouse/keyboard emulation mode.
        pub fn set_mouse(&self, allow_mouse: bool) {
            let mut state = self.state.lock().unwrap();
            if state.allow_mouse != allow_mouse {
                if state.allow_mouse {
                    release_desktop(&mut state);
                    self.ticking.store(false, Ordering::SeqCst);
                } else {
                    release_vigem(&mut state);
                }
                state.allow_mouse = allow_mouse;
            }
            if !allow_mouse && state.vigem.is_none() {
                state.vigem = Vigem::connect();
            }
            let has_vigem = state.vigem.is_some();
            drop(state);
            emit_status(&self.out, has_vigem, allow_mouse);
        }

        pub fn post(&self, op: &Value) {
            let Some((index, pad)) = of(op) else { return };
            let mut state = self.state.lock().unwrap();
            if !state.allow_mouse {
                state.pads[index] = pad;
                if let Some(vigem) = state.vigem.as_ref() {
                    match (pad, state.targets[index]) {
                        (Some(p), Some(serial)) => vigem.update(serial, report(&p)),
                        (Some(p), None) => {
                            if let Some(serial) = vigem.add() {
                                vigem.update(serial, report(&p));
                                state.targets[index] = Some(serial);
                            }
                        }
                        (None, Some(serial)) => {
                            vigem.remove(serial);
                            state.targets[index] = None;
                        }
                        (None, None) => {}
                    }
                }
                return;
            }
            let was = state.pads[index].unwrap_or_default();
            state.pads[index] = pad;
            let now = pad.unwrap_or_default();
            for (b, down) in changes(was.held(), now.held()) {
                match does(b) {
                    Some(Does::Mouse(m)) => {
                        let held_before = state.mouse;
                        if down { state.mouse |= m } else { state.mouse &= !m }
                        if held_before != state.mouse {
                            let flags = match (m, down) {
                                (1, true) => MOUSEEVENTF_LEFTDOWN,
                                (1, false) => MOUSEEVENTF_LEFTUP,
                                (_, true) => MOUSEEVENTF_RIGHTDOWN,
                                (_, false) => MOUSEEVENTF_RIGHTUP,
                            };
                            send(&[mouse(0, 0, 0, flags)]);
                        }
                    }
                    Some(Does::Key { scan, ext, shift }) => {
                        let mut inputs = Vec::new();
                        if shift && down {
                            inputs.push(key(0x2a, false, true));
                        }
                        inputs.push(key(scan, ext, down));
                        if shift && down {
                            inputs.push(key(0x2a, false, false));
                        }
                        send(&inputs);
                    }
                    None => {}
                }
            }
            let moving = state.pads.iter().flatten().any(|p| p.moving());
            drop(state);
            if moving && !self.ticking.swap(true, Ordering::SeqCst) {
                self.tick();
            }
        }

        /// While a stick is pushed in mouse emulation mode: the pointer and the wheels moved each tick.
        fn tick(&self) {
            let (state, ticking, moved) = (self.state.clone(), self.ticking.clone(), self.moved.clone());
            std::thread::spawn(move || {
                while ticking.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(TICK_MS));
                    let mut s = state.lock().unwrap();
                    if !s.allow_mouse {
                        ticking.store(false, Ordering::SeqCst);
                        break;
                    }
                    let total = s.pads.iter().flatten().map(|p| step(p, TICK_MS as f64)).fold((0.0, 0.0, 0.0, 0.0), |a, d| (a.0 + d.0, a.1 + d.1, a.2 + d.2, a.3 + d.3));
                    if total == (0.0, 0.0, 0.0, 0.0) {
                        ticking.store(false, Ordering::SeqCst);
                        break;
                    }
                    let (dx, dy) = (s.carry.0.take(total.0), s.carry.1.take(total.1));
                    let mut inputs = Vec::new();
                    if dx != 0 || dy != 0 {
                        inputs.push(mouse(dx, dy, 0, MOUSEEVENTF_MOVE));
                    }
                    s.carry.2 += total.2;
                    s.carry.3 += total.3;
                    let (wx, wy) = (s.carry.2.trunc(), s.carry.3.trunc());
                    s.carry.2 -= wx;
                    s.carry.3 -= wy;
                    if wy != 0.0 {
                        inputs.push(mouse(0, 0, wy as i32, MOUSEEVENTF_WHEEL));
                    }
                    if wx != 0.0 {
                        inputs.push(mouse(0, 0, wx as i32, MOUSEEVENTF_HWHEEL));
                    }
                    drop(s);
                    if dx != 0 || dy != 0 {
                        moved();
                    }
                    send(&inputs);
                }
            });
        }

        /// Every controller let go of.
        pub fn release(&self) {
            let mut state = self.state.lock().unwrap();
            release_vigem(&mut state);
            if state.allow_mouse {
                release_desktop(&mut state);
            }
            self.ticking.store(false, Ordering::SeqCst);
        }
    }

    impl Drop for Gamepads {
        fn drop(&mut self) {
            self.release();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn vigem_ioctl_codes_and_struct_sizes_match_driver_abi() {
        assert_eq!(IOCTL_VIGEM_PLUGIN_TARGET, 0x002A_A004);
        assert_eq!(IOCTL_VIGEM_UNPLUG_TARGET, 0x002A_A008);
        assert_eq!(IOCTL_VIGEM_CHECK_VERSION, 0x002A_A00C);
        assert_eq!(IOCTL_VIGEM_WAIT_DEVICE_READY, 0x002A_A010);
        assert_eq!(IOCTL_XUSB_SUBMIT_REPORT, 0x002A_A808);
        assert_eq!(std::mem::size_of::<VigemCheckVersion>(), 8);
        assert_eq!(std::mem::size_of::<VigemPluginTarget>(), 16);
        assert_eq!(std::mem::size_of::<VigemSerial>(), 8);
        assert_eq!(std::mem::size_of::<Report>(), 12);
        assert_eq!(std::mem::size_of::<XusbSubmitReport>(), 20);
    }

    #[test]
    fn an_op_is_a_slot_and_its_state() {
        assert_eq!(of(&json!({ "index": 4, "buttons": 0 })), None);
        assert_eq!(of(&json!({ "index": 1, "connected": false })), Some((1, None)));
        let (i, p) = of(&json!({ "index": 2, "buttons": 0x3ffff, "lx": 2.0, "ly": -0.5, "lt": -1.0, "rt": 0.7 })).unwrap();
        assert_eq!(i, 2);
        let p = p.unwrap();
        assert_eq!((p.buttons, p.lx, p.ly, p.lt, p.rt), (0x1ffff, 1.0, -0.5, 0.0, 0.7));
    }

    #[test]
    fn xinputs_report_has_its_sticks_up_positive() {
        let r = report(&Pad { buttons: (1 << bit::A) | (1 << bit::UP) | (1 << bit::HOME), lx: 1.0, ly: 1.0, rx: -1.0, ry: -0.5, lt: 0.5, rt: 0.0 });
        assert_eq!(r.buttons, 0x1000 | 0x0001 | 0x0400);
        assert_eq!((r.lx, r.ly, r.rx, r.ry), (32767, -32768, -32768, 16384));
        assert_eq!((r.left_trigger, r.right_trigger), (128, 0));
        // a trigger said pressed with no value is full
        assert_eq!(report(&Pad { buttons: 1 << bit::RT, ..Pad::default() }).right_trigger, 255);
        assert_eq!(std::mem::size_of::<Report>(), 12);
    }

    #[test]
    fn a_sticks_rest_is_no_move_and_its_step_grows_squared() {
        assert_eq!(past(0.1), 0.0);
        assert_eq!(past(-1.0), -1.0);
        assert!(!Pad { lx: 0.1, ..Pad::default() }.moving());
        let (dx, dy, wx, wy) = step(&Pad { lx: 1.0, ly: -1.0, rx: 0.0, ry: 1.0, ..Pad::default() }, 1000.0);
        assert_eq!((dx, dy, wx, wy), (POINTER_SPEED, -POINTER_SPEED, 0.0, -WHEEL_SPEED));
        let half = DEAD_ZONE + (1.0 - DEAD_ZONE) / 2.0;
        assert!((step(&Pad { lx: half, ..Pad::default() }, 1000.0).0 - POINTER_SPEED / 4.0).abs() < 1e-9);
    }

    #[test]
    fn buttons_drive_the_desktop_as_the_stations_map_says() {
        assert_eq!(does(bit::A), Some(Does::Mouse(1)));
        assert_eq!(does(bit::B), Some(Does::Mouse(2)));
        assert_eq!(does(bit::LB), Some(Does::Key { scan: 0x0f, ext: false, shift: true }));
        assert_eq!(does(bit::UP), Some(Does::Key { scan: 0x48, ext: true, shift: false }));
        assert_eq!(does(bit::HOME), None);
        let p = Pad { buttons: 1 << bit::LT, lt: 0.2, rt: 0.9, ..Pad::default() };
        assert_eq!(p.held(), 1 << bit::RT);
        assert_eq!(changes(0b101, 0b110), vec![(0, false), (1, true)]);
    }
}
