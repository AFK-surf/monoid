// A person's game controllers on this machine (`{op: "gamepad"}`, station/src/screens/win-input.ts): a virtual Xbox
// 360 controller each (XInput's, which every game reads) where ViGEmBus is installed, through ViGEmClient.dll loaded
// from System32 alone (never the current or the program's directory: a DLL put there would run as the station);
// where it is not, they drive the desktop as station/src/screens/gamepad-desktop.ts maps one: the pointer by the left
// stick, the wheel by the right, A the left button, B the right, X Escape, Y Enter, LB Shift+Tab, RB Tab, LT Page Up,
// RT Page Down, Back Backspace, Start Space, the d-pad the arrow keys, a stick held moving the pointer 60 times a
// second. A controller let go of (`connected: false`, the view's end) lets go of all it holds.
use serde_json::Value;

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
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use serde_json::Value;
    use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    use windows::core::{s, w};

    use super::{Does, Pad, Report, TICK_MS, changes, does, of, report, step};
    use crate::Out;
    use crate::mouse::Carry;

    type Client = *mut core::ffi::c_void;
    type Target = *mut core::ffi::c_void;
    const VIGEM_ERROR_NONE: u32 = 0x2000_0000;

    /// ViGEmClient's calls, found in System32's copy.
    struct Vigem {
        client: Client,
        target_alloc: unsafe extern "C" fn() -> Target,
        target_add: unsafe extern "C" fn(Client, Target) -> u32,
        target_remove: unsafe extern "C" fn(Client, Target) -> u32,
        target_free: unsafe extern "C" fn(Target),
        update: unsafe extern "C" fn(Client, Target, Report) -> u32,
        disconnect: unsafe extern "C" fn(Client),
        free: unsafe extern "C" fn(Client),
    }

    // (ViGEmClient's handles are used from one thread at a time, behind the state's lock)
    unsafe impl Send for Vigem {}

    impl Vigem {
        fn load() -> Option<Vigem> {
            unsafe {
                let module = LoadLibraryExW(w!("ViGEmClient.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32).ok()?;
                macro_rules! find {
                    ($name:expr, $ty:ty) => {
                        std::mem::transmute::<_, $ty>(GetProcAddress(module, $name)?)
                    };
                }
                let alloc = find!(s!("vigem_alloc"), unsafe extern "C" fn() -> Client);
                let connect = find!(s!("vigem_connect"), unsafe extern "C" fn(Client) -> u32);
                let mut vigem = Vigem {
                    client: std::ptr::null_mut(),
                    target_alloc: find!(s!("vigem_target_x360_alloc"), unsafe extern "C" fn() -> Target),
                    target_add: find!(s!("vigem_target_add"), unsafe extern "C" fn(Client, Target) -> u32),
                    target_remove: find!(s!("vigem_target_remove"), unsafe extern "C" fn(Client, Target) -> u32),
                    target_free: find!(s!("vigem_target_free"), unsafe extern "C" fn(Target)),
                    update: find!(s!("vigem_target_x360_update"), unsafe extern "C" fn(Client, Target, Report) -> u32),
                    disconnect: find!(s!("vigem_disconnect"), unsafe extern "C" fn(Client)),
                    free: find!(s!("vigem_free"), unsafe extern "C" fn(Client)),
                };
                let client = alloc();
                if client.is_null() {
                    return None;
                }
                if connect(client) != VIGEM_ERROR_NONE {
                    (vigem.free)(client);
                    return None;
                }
                vigem.client = client;
                Some(vigem)
            }
        }

        fn add(&self) -> Option<Target> {
            unsafe {
                let target = (self.target_alloc)();
                if target.is_null() {
                    return None;
                }
                if (self.target_add)(self.client, target) != VIGEM_ERROR_NONE {
                    (self.target_free)(target);
                    return None;
                }
                Some(target)
            }
        }

        fn remove(&self, target: Target) {
            unsafe {
                let _ = (self.update)(self.client, target, Report::default());
                let _ = (self.target_remove)(self.client, target);
                (self.target_free)(target);
            }
        }
    }

    impl Drop for Vigem {
        fn drop(&mut self) {
            if self.client.is_null() {
                return;
            }
            unsafe {
                (self.disconnect)(self.client);
                (self.free)(self.client);
            }
        }
    }

    struct State {
        pads: [Option<Pad>; 4],
        /// Where ViGEmBus is: each slot's virtual controller.
        vigem: Option<Vigem>,
        targets: [Option<Target>; 4],
        /// The mouse buttons the desktop's controllers hold (1 left, 2 right), and the parts of a pixel and of a
        /// wheel's unit not posted yet.
        mouse: u8,
        carry: (Carry, Carry, f64, f64),
    }

    unsafe impl Send for State {}

    pub struct Gamepads {
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

    impl Gamepads {
        /// `moved`: told of each move it posts (pointer_lock.rs's moves).
        pub fn new(out: &Out, moved: impl Fn() + Send + Sync + 'static) -> Gamepads {
            let vigem = Vigem::load();
            out.json(4, serde_json::json!({ "gamepads": if vigem.is_some() { "ViGEmBus" } else { "desktop" } }));
            Gamepads {
                state: Arc::new(Mutex::new(State { pads: [None; 4], vigem, targets: [None; 4], mouse: 0, carry: (Carry::default(), Carry::default(), 0.0, 0.0) })),
                ticking: Arc::new(AtomicBool::new(false)),
                moved: Arc::new(moved),
            }
        }

        pub fn post(&self, op: &Value) {
            let Some((index, pad)) = of(op) else { return };
            let mut state = self.state.lock().unwrap();
            let was = state.pads[index].unwrap_or_default();
            state.pads[index] = pad;
            let now = pad.unwrap_or_default();
            if state.vigem.is_some() {
                let vigem = state.vigem.as_ref().unwrap();
                match (pad, state.targets[index]) {
                    (Some(p), Some(target)) => unsafe {
                        let _ = (vigem.update)(vigem.client, target, report(&p));
                    },
                    (Some(p), None) => {
                        if let Some(target) = vigem.add() {
                            unsafe {
                                let _ = (vigem.update)(vigem.client, target, report(&p));
                            }
                            state.targets[index] = Some(target);
                        }
                    }
                    (None, Some(target)) => {
                        vigem.remove(target);
                        state.targets[index] = None;
                    }
                    (None, None) => {}
                }
                return;
            }
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

        /// While a stick is pushed: the pointer and the wheels moved each tick.
        fn tick(&self) {
            let (state, ticking, moved) = (self.state.clone(), self.ticking.clone(), self.moved.clone());
            std::thread::spawn(move || {
                while ticking.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(TICK_MS));
                    let mut s = state.lock().unwrap();
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
            for index in 0..4 {
                self.post(&serde_json::json!({ "index": index, "connected": false }));
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
