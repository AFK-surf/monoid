// Session-N LocalSystem worker for stillfail-screen-svc:
// - Runs inside the active interactive console session (WinSta0) under the LocalSystem token.
// - Serves a security-hardened local Named Pipe (DACL restricted to SYSTEM, Administrators, and AllowedUserSid,
//   with PIPE_REJECT_REMOTE_CLIENTS and connecting-executable verification).
// - Routes human remote input through OpenInputDesktop + SetThreadDesktop + SendInput (and SendSAS), covering
//   elevated windows (UIPI), UAC secure desktop (Winlogon), and the lock screen.
// - Watches desktop transitions and streams Winlogon frames (DXGI Desktop Duplication with HDR tone-mapping and GDI
//   fallback) plus live cursor coordinates whenever Windows is on a secure desktop.
use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use windows::Win32::Foundation::{
    CloseHandle, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, GENERIC_ALL, HANDLE, HLOCAL, HMODULE, INVALID_HANDLE_VALUE,
    LocalFree, POINT,
};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_RATIONAL, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTPUT_DESC, IDXGIAdapter, IDXGIDevice, IDXGIOutput,
    IDXGIOutput1, IDXGIOutput5, IDXGIOutputDuplication, DXGI_OUTDUPL_FRAME_INFO,
};
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleBitmap, CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC,
    DeleteObject, GetDC, GetDIBits, HALFTONE, HGDIOBJ, ReleaseDC, SRCCOPY, SelectObject, SetStretchBltMode, StretchBlt,
};
use windows::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows::Win32::Storage::FileSystem::{FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX};
use windows::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};
use windows::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, DESKTOP_READOBJECTS, GetUserObjectInformationW, HDESK, OpenInputDesktop, SetThreadDesktop, UOI_NAME,
};
use windows::Win32::System::Threading::{
    CreateEventW, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CURSOR_SHOWING, CURSORINFO, GetCursorInfo, HCURSOR, IDC_APPSTARTING, IDC_ARROW, IDC_CROSS, IDC_HAND, IDC_IBEAM,
    IDC_NO, IDC_SIZEALL, IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE, IDC_WAIT, LoadCursorW,
};
use windows::core::{HSTRING, Interface, PWSTR};

use super::display::{dpi_aware, main_display};
use super::hdr;
use super::input::Input;
use super::svc_pipe::{self, PipeHandle, PipeWriter};
use super::svc_proto::{
    self, KIND_CURSOR, KIND_DESKTOP, KIND_FRAME, KIND_FRAME_REQ, KIND_HELLO, KIND_INPUT, MAX_CONTROL_BYTES, PIPE_NAME,
    PROTO_VERSION,
};

fn now_us() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_micros() as i64).unwrap_or(0)
}

fn desktop_name_of(desk: HDESK) -> Option<String> {
    let mut buf = [0u16; 128];
    let mut needed = 0u32;
    unsafe {
        GetUserObjectInformationW(
            HANDLE(desk.0),
            UOI_NAME,
            Some(buf.as_mut_ptr() as *mut _),
            (buf.len() * 2) as u32,
            Some(&mut needed),
        )
        .ok()?;
    }
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..end]))
}

/// Reads the name of the session's active input desktop (e.g. "Default", "Winlogon").
pub fn active_desktop_name() -> Option<String> {
    unsafe {
        let desk = OpenInputDesktop(Default::default(), false, DESKTOP_READOBJECTS).ok()?;
        let name = desktop_name_of(desk);
        let _ = CloseDesktop(desk);
        name
    }
}

/// Opens the active input desktop with desktop-switch/write/read rights and attaches the calling thread to it.
fn attach_input_desktop() -> Option<(HDESK, String)> {
    const DESKTOP_ALL_SPECIFIC: u32 = 0x01FF;
    const MAXIMUM_ALLOWED: u32 = 0x0200_0000;
    unsafe {
        let desk = OpenInputDesktop(
            Default::default(),
            false,
            windows::Win32::System::StationsAndDesktops::DESKTOP_ACCESS_FLAGS(DESKTOP_ALL_SPECIFIC),
        )
        .or_else(|_| {
            OpenInputDesktop(
                Default::default(),
                false,
                windows::Win32::System::StationsAndDesktops::DESKTOP_ACCESS_FLAGS(MAXIMUM_ALLOWED),
            )
        })
        .or_else(|_| {
            OpenInputDesktop(
                Default::default(),
                false,
                windows::Win32::System::StationsAndDesktops::DESKTOP_ACCESS_FLAGS(GENERIC_ALL.0),
            )
        })
        .ok()?;
        let name = desktop_name_of(desk).unwrap_or_default();
        if SetThreadDesktop(desk).is_err() {
            let _ = CloseDesktop(desk);
            return None;
        }
        Some((desk, name))
    }
}

/// Keeps the calling thread (which must own no windows/hooks) attached to the current active input desktop.
struct DesktopSwitch {
    desk: Option<HDESK>,
    name: String,
    last_check: Instant,
}

impl DesktopSwitch {
    fn new() -> Self {
        let mut s = Self { desk: None, name: String::new(), last_check: Instant::now() - Duration::from_secs(1) };
        s.sync(true);
        s
    }

    fn sync(&mut self, force: bool) {
        if !force && self.last_check.elapsed() < Duration::from_millis(25) {
            return;
        }
        self.last_check = Instant::now();
        let Some(now) = active_desktop_name() else {
            return;
        };
        if now.eq_ignore_ascii_case(&self.name) && self.desk.is_some() {
            return;
        }
        if let Some((new_desk, actual)) = attach_input_desktop() {
            if let Some(old) = self.desk.replace(new_desk) {
                unsafe {
                    let _ = CloseDesktop(old);
                }
            }
            self.name = actual;
        }
    }
}

impl Drop for DesktopSwitch {
    fn drop(&mut self) {
        if let Some(d) = self.desk.take() {
            unsafe {
                let _ = CloseDesktop(d);
            }
        }
    }
}

fn verify_pipe_client(pipe: HANDLE) -> bool {
    unsafe {
        let mut pid = 0u32;
        if GetNamedPipeClientProcessId(pipe, &mut pid).is_err() || pid == 0 {
            return false;
        }
        let Ok(proc) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(proc, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(proc);
        if !ok || len == 0 {
            return false;
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        svc_proto::is_allowed_client_exe(&path)
    }
}

/// Runs the Session-N SYSTEM worker pipe server until terminated.
pub fn run_worker(session_id: u32, user_sid: &str) -> Result<(), String> {
    dpi_aware();
    let sddl = svc_proto::pipe_sddl(user_sid).ok_or_else(|| format!("invalid user SID: {user_sid}"))?;
    let mut sd = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(&HSTRING::from(&sddl), SDDL_REVISION_1, &mut sd, None)
            .map_err(|e| format!("ConvertStringSecurityDescriptorToSecurityDescriptorW: {e}"))?;
    }
    let _sd_guard = LocalMemGuard(sd.0);

    let pipe_wide = HSTRING::from(PIPE_NAME);
    let connect_event = unsafe { CreateEventW(None, true, false, None) }.map_err(|e| format!("CreateEventW: {e}"))?;

    loop {
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: false.into(),
        };
        let pipe = unsafe {
            CreateNamedPipeW(
                &pipe_wide,
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                16,
                4 * 1024 * 1024,
                64 * 1024,
                0,
                Some(&sa),
            )
        };
        if pipe.is_invalid() || pipe == INVALID_HANDLE_VALUE {
            std::thread::sleep(Duration::from_millis(250));
            continue;
        }

        let mut ov = OVERLAPPED { hEvent: connect_event, ..Default::default() };
        let connected = match unsafe { ConnectNamedPipe(pipe, Some(&mut ov)) } {
            Ok(()) => true,
            Err(e) => {
                let code = e.code().0 as u32 & 0xFFFF;
                if code == ERROR_PIPE_CONNECTED.0 {
                    true
                } else if code == ERROR_IO_PENDING.0 {
                    let mut dummy = 0u32;
                    unsafe { GetOverlappedResult(pipe, &ov, &mut dummy, true) }.is_ok()
                } else {
                    false
                }
            }
        };

        if !connected || !verify_pipe_client(pipe) {
            unsafe {
                let _ = DisconnectNamedPipe(pipe);
                let _ = CloseHandle(pipe);
            }
            continue;
        }

        let handle = PipeHandle::from_raw(pipe);
        let _ = std::thread::Builder::new().name("svc-client".into()).spawn(move || {
            handle_client(handle, session_id);
        });
    }
}

struct LocalMemGuard(*mut core::ffi::c_void);

impl Drop for LocalMemGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = LocalFree(Some(HLOCAL(self.0)));
            }
        }
    }
}

fn handle_client(handle: Arc<PipeHandle>, session_id: u32) {
    let Ok((mut reader, mut writer)) = svc_pipe::split(handle.clone()) else {
        return;
    };
    let Ok(Some((KIND_HELLO, payload))) = svc_proto::read_msg(&mut reader, MAX_CONTROL_BYTES) else {
        return;
    };
    let Ok(hello) = serde_json::from_slice::<Value>(&payload) else {
        return;
    };
    if hello["version"].as_u64() != Some(PROTO_VERSION as u64) {
        let _ = svc_proto::write_json(&mut writer, KIND_HELLO, &json!({ "ok": false, "error": "unsupported version" }));
        return;
    }

    let desktop = active_desktop_name().unwrap_or_else(|| "Default".to_string());
    let secure = svc_proto::is_secure_desktop(&desktop);
    let ack = json!({
        "version": PROTO_VERSION,
        "ok": true,
        "desktop": desktop,
        "secure": secure,
        "session": session_id,
    });
    if svc_proto::write_json(&mut writer, KIND_HELLO, &ack).is_err() {
        return;
    }

    let want_input = hello["input"].as_bool() == Some(true);
    let want_capture = hello["capture"].as_bool() == Some(true);

    if want_input {
        let mut keys = Input::new();
        let mut desk = DesktopSwitch::new();
        while let Ok(Some((kind, data))) = svc_proto::read_msg(&mut reader, MAX_CONTROL_BYTES) {
            if kind == KIND_INPUT {
                if let Ok(op) = serde_json::from_slice::<Value>(&data) {
                    let is_move = op["op"].as_str() == Some("mouse") && op["type"].as_str() == Some("move");
                    desk.sync(!is_move);
                    keys.post(&op);
                }
            }
        }
        return;
    }

    if want_capture {
        let init_w = hello["maxWidth"].as_u64().unwrap_or(1920).clamp(16, 3840) as u32;
        let init_h = hello["maxHeight"].as_u64().unwrap_or(1080).clamp(16, 2160) as u32;
        let writer = Arc::new(Mutex::new(writer));
        let req = Arc::new((Mutex::new(CapReq { wanted: 0, max_w: init_w, max_h: init_h, closed: false }), Condvar::new()));

        let req_rd = req.clone();
        let _ = std::thread::Builder::new().name("svc-cap-req".into()).spawn(move || {
            while let Ok(Some((kind, data))) = svc_proto::read_msg(&mut reader, MAX_CONTROL_BYTES) {
                if kind == KIND_FRAME_REQ {
                    let (mut mw, mut mh) = (0u32, 0u32);
                    if let Ok(v) = serde_json::from_slice::<Value>(&data) {
                        mw = v["maxWidth"].as_u64().unwrap_or(0) as u32;
                        mh = v["maxHeight"].as_u64().unwrap_or(0) as u32;
                    }
                    let mut st = req_rd.0.lock().unwrap();
                    if mw >= 16 && mh >= 16 {
                        st.max_w = mw.min(3840);
                        st.max_h = mh.min(2160);
                    }
                    st.wanted = st.wanted.saturating_add(1).min(4);
                    req_rd.1.notify_all();
                }
            }
            let mut st = req_rd.0.lock().unwrap();
            st.closed = true;
            req_rd.1.notify_all();
        });

        let mut last_name = desktop;
        let mut last_secure = secure;

        loop {
            if req.0.lock().unwrap().closed {
                break;
            }
            if last_secure {
                let stop_cap = Arc::new(AtomicBool::new(false));
                let stop_bg = stop_cap.clone();
                let w_bg = writer.clone();
                let req_bg = req.clone();
                let cap_thread = std::thread::Builder::new()
                    .name("svc-winlogon-cap".into())
                    .spawn(move || winlogon_capture_loop(w_bg, req_bg, stop_bg))
                    .ok();

                loop {
                    {
                        let st = req.0.lock().unwrap();
                        if st.closed {
                            break;
                        }
                    }
                    std::thread::sleep(Duration::from_millis(40));
                    if let Some(now_name) = active_desktop_name() {
                        let now_sec = svc_proto::is_secure_desktop(&now_name);
                        if !now_sec || !now_name.eq_ignore_ascii_case(&last_name) {
                            last_name = now_name;
                            last_secure = now_sec;
                            break;
                        }
                    }
                }
                stop_cap.store(true, Ordering::Relaxed);
                req.1.notify_all();
                if let Some(t) = cap_thread {
                    let _ = t.join();
                }
                let ok = {
                    let mut w = writer.lock().unwrap();
                    svc_proto::write_json(&mut *w, KIND_DESKTOP, &json!({ "name": last_name, "secure": last_secure })).is_ok()
                };
                if !ok {
                    break;
                }
            } else {
                let st = req.0.lock().unwrap();
                let (st, _) = req.1.wait_timeout(st, Duration::from_millis(40)).unwrap();
                if st.closed {
                    break;
                }
                drop(st);
                if let Some(now_name) = active_desktop_name() {
                    if !now_name.eq_ignore_ascii_case(&last_name) {
                        last_secure = svc_proto::is_secure_desktop(&now_name);
                        last_name = now_name;
                        let ok = {
                            let mut w = writer.lock().unwrap();
                            svc_proto::write_json(&mut *w, KIND_DESKTOP, &json!({ "name": last_name, "secure": last_secure })).is_ok()
                        };
                        if !ok {
                            break;
                        }
                    }
                }
            }
        }
    }
}

struct CapReq {
    wanted: u32,
    max_w: u32,
    max_h: u32,
    closed: bool,
}

/// Runs on a dedicated fresh thread so SetThreadDesktop(Winlogon) always succeeds cleanly.
fn winlogon_capture_loop(writer: Arc<Mutex<PipeWriter>>, req: Arc<(Mutex<CapReq>, Condvar)>, stop: Arc<AtomicBool>) {
    let Some((desk, _)) = attach_input_desktop() else {
        return;
    };
    let _desk_guard = DeskGuard(desk);

    let shapes = cursor_shapes();
    let mut last_cursor = String::new();
    let mut last_cursor_at = Instant::now() - Duration::from_secs(1);

    let mut dxgi = DxgiDup::open().ok();
    let entered = Instant::now();
    let mut first_sent = false;
    let mut last_gdi_hash = 0u64;
    let mut last_gdi_at = Instant::now() - Duration::from_secs(1);

    while !stop.load(Ordering::Relaxed) {
        // Send live cursor updates while on Winlogon so remote user sees pointer over UAC Yes / PIN input.
        if last_cursor_at.elapsed() >= Duration::from_millis(20) {
            last_cursor_at = Instant::now();
            if let Some(cur_json) = sample_cursor(&shapes) {
                if cur_json != last_cursor {
                    last_cursor = cur_json;
                    let mut w = writer.lock().unwrap();
                    if svc_proto::write_msg(&mut *w, KIND_CURSOR, last_cursor.as_bytes()).is_err() {
                        return;
                    }
                }
            }
        }

        let (wanted, max_w, max_h, closed) = {
            let st = req.0.lock().unwrap();
            (st.wanted, st.max_w, st.max_h, st.closed)
        };
        if closed {
            return;
        }
        if wanted == 0 {
            let st = req.0.lock().unwrap();
            let _ = req.1.wait_timeout(st, Duration::from_millis(20));
            continue;
        }

        let mut frame: Option<(u32, u32, Vec<u8>)> = None;

        if let Some(dup) = dxgi.as_mut() {
            match dup.grab(max_w, max_h, 40, !first_sent) {
                Ok(Some(f)) => frame = Some(f),
                Ok(None) => {
                    // Timeout: if we haven't delivered an initial frame within 150ms, fall back to GDI once.
                    if !first_sent && entered.elapsed() >= Duration::from_millis(150) {
                        frame = gdi_grab(max_w, max_h);
                    }
                }
                Err(DupErr::AccessLost) => {
                    dxgi = None;
                    // Re-attach in case Winlogon recreated or transitioned, then retry opening DXGI.
                    if !stop.load(Ordering::Relaxed) {
                        dxgi = DxgiDup::open().ok();
                    }
                }
                Err(DupErr::Other) => {
                    dxgi = None;
                }
            }
        } else if last_gdi_at.elapsed() >= Duration::from_millis(66) {
            last_gdi_at = Instant::now();
            if let Some((w, h, pixels)) = gdi_grab(max_w, max_h) {
                let hash = quick_hash(&pixels);
                if !first_sent || hash != last_gdi_hash {
                    last_gdi_hash = hash;
                    frame = Some((w, h, pixels));
                }
            }
        } else {
            std::thread::sleep(Duration::from_millis(16));
        }

        if let Some((w, h, bgra)) = frame {
            if let Some(payload) = svc_proto::encode_frame_payload(w, h, now_us(), &bgra) {
                let sent_ok = {
                    let mut wr = writer.lock().unwrap();
                    svc_proto::write_msg(&mut *wr, KIND_FRAME, &payload).is_ok()
                };
                if !sent_ok {
                    return;
                }
                first_sent = true;
                let mut st = req.0.lock().unwrap();
                st.wanted = st.wanted.saturating_sub(1);
            }
        }
    }
}

struct DeskGuard(HDESK);

impl Drop for DeskGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseDesktop(self.0);
        }
    }
}

fn quick_hash(bytes: &[u8]) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325u64;
    let step = (bytes.len() / 2048).max(1);
    for &b in bytes.iter().step_by(step) {
        h ^= b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

fn cursor_shapes() -> Vec<(HCURSOR, &'static str)> {
    [
        (IDC_ARROW, "default"),
        (IDC_IBEAM, "text"),
        (IDC_HAND, "pointer"),
        (IDC_SIZEWE, "ew-resize"),
        (IDC_SIZENS, "ns-resize"),
        (IDC_SIZENWSE, "nwse-resize"),
        (IDC_SIZENESW, "nesw-resize"),
        (IDC_SIZEALL, "move"),
        (IDC_CROSS, "crosshair"),
        (IDC_NO, "not-allowed"),
        (IDC_WAIT, "wait"),
        (IDC_APPSTARTING, "progress"),
    ]
    .into_iter()
    .filter_map(|(id, name)| unsafe { LoadCursorW(None, id) }.ok().map(|c| (c, name)))
    .collect()
}

fn sample_cursor(shapes: &[(HCURSOR, &'static str)]) -> Option<String> {
    let mut info = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
    unsafe { GetCursorInfo(&mut info) }.ok()?;
    let (_, rect) = main_display();
    let (w, h) = ((rect.right - rect.left).max(1) as f64, (rect.bottom - rect.top).max(1) as f64);
    let POINT { x, y } = info.ptScreenPos;
    let unit = |v: f64| (v.clamp(0.0, 1.0) * 10000.0).round() / 10000.0;
    let shape = if info.flags.0 & CURSOR_SHOWING.0 == 0 {
        "none"
    } else {
        shapes.iter().find(|(c, _)| *c == info.hCursor).map(|(_, n)| *n).unwrap_or("default")
    };
    Some(json!({ "x": unit((x - rect.left) as f64 / w), "y": unit((y - rect.top) as f64 / h), "shape": shape }).to_string())
}

enum DupErr {
    AccessLost,
    Other,
}

struct DxgiDup {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    video: ID3D11VideoDevice,
    vcontext: ID3D11VideoContext,
    dupl: IDXGIOutputDuplication,
    sdr: Option<hdr::ToSdr>,
    sdr_target: Option<ID3D11Texture2D>,
    vp_from: (u32, u32),
    vp_to: (u32, u32),
    vp_enum: Option<ID3D11VideoProcessorEnumerator>,
    vp: Option<ID3D11VideoProcessor>,
    vp_out: Option<(ID3D11Texture2D, ID3D11VideoProcessorOutputView)>,
    staging: Option<ID3D11Texture2D>,
}

impl DxgiDup {
    fn open() -> windows::core::Result<Self> {
        let levels = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1];
        let (mut device, mut context) = (None, None);
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
        }
        let device = device.unwrap();
        let context = context.unwrap();
        let video: ID3D11VideoDevice = device.cast()?;
        let vcontext: ID3D11VideoContext = context.cast()?;

        let dxgi_dev: IDXGIDevice = device.cast()?;
        let adapter: IDXGIAdapter = unsafe { dxgi_dev.GetAdapter()? };
        let (primary_mon, _) = main_display();

        let mut chosen: Option<IDXGIOutput> = None;
        let mut first: Option<IDXGIOutput> = None;
        for idx in 0..16 {
            let Ok(out) = (unsafe { adapter.EnumOutputs(idx) }) else {
                break;
            };
            if first.is_none() {
                first = Some(out.clone());
            }
            if let Ok(desc) = unsafe { out.GetDesc() } {
                let desc: DXGI_OUTPUT_DESC = desc;
                if desc.Monitor == primary_mon {
                    chosen = Some(out);
                    break;
                }
            }
        }
        let output = chosen.or(first).ok_or_else(|| windows::core::Error::from_hresult(DXGI_ERROR_ACCESS_LOST))?;
        let sdr = hdr::sdr_white(primary_mon).and_then(|white| hdr::ToSdr::new(&device, white).ok());

        // Prefer DuplicateOutput1 with FP16 when HDR is active so UAC/lock screen isn't washed out.
        let dupl = if sdr.is_some() {
            let formats = [DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_B8G8R8A8_UNORM];
            output
                .cast::<IDXGIOutput5>()
                .and_then(|o5| unsafe { o5.DuplicateOutput1(&device, 0, &formats) })
                .or_else(|_| output.cast::<IDXGIOutput1>().and_then(|o1| unsafe { o1.DuplicateOutput(&device) }))?
        } else {
            let o1: IDXGIOutput1 = output.cast()?;
            unsafe { o1.DuplicateOutput(&device)? }
        };

        Ok(Self {
            device,
            context,
            video,
            vcontext,
            dupl,
            sdr,
            sdr_target: None,
            vp_from: (0, 0),
            vp_to: (0, 0),
            vp_enum: None,
            vp: None,
            vp_out: None,
            staging: None,
        })
    }

    fn grab(&mut self, max_w: u32, max_h: u32, timeout_ms: u32, force_first: bool) -> Result<Option<(u32, u32, Vec<u8>)>, DupErr> {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource = None;
        let res = unsafe { self.dupl.AcquireNextFrame(timeout_ms, &mut info, &mut resource) };
        if let Err(e) = res {
            if e.code() == DXGI_ERROR_WAIT_TIMEOUT {
                return Ok(None);
            }
            if e.code() == DXGI_ERROR_ACCESS_LOST {
                return Err(DupErr::AccessLost);
            }
            return Err(DupErr::Other);
        }

        // Skip pointer-only DXGI wakes when pixels did not change (cursor moves are sent separately via KIND_CURSOR).
        if !force_first && info.LastPresentTime == 0 && info.AccumulatedFrames == 0 {
            unsafe {
                let _ = self.dupl.ReleaseFrame();
            }
            return Ok(None);
        }

        let extracted = (|| -> windows::core::Result<(u32, u32, Vec<u8>)> {
            let src: ID3D11Texture2D = resource.unwrap().cast()?;
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            unsafe { src.GetDesc(&mut desc) };
            let (sw, sh) = (desc.Width, desc.Height);

            let bgra_src = if desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT {
                if let Some(sdr) = self.sdr.as_mut() {
                    let fits = self.sdr_target.as_ref().is_some_and(|t| {
                        let mut d = D3D11_TEXTURE2D_DESC::default();
                        unsafe { t.GetDesc(&mut d) };
                        d.Width == sw && d.Height == sh
                    });
                    if !fits {
                        self.sdr_target = Some(make_tex(&self.device, sw, sh, DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE)?);
                    }
                    let target = self.sdr_target.as_ref().unwrap();
                    sdr.run(&self.device, &self.context, &src, target, sw, sh)?;
                    target.clone()
                } else {
                    src
                }
            } else {
                src
            };

            let (tw, th) = svc_proto::fit_even(sw, sh, max_w, max_h);
            let final_tex = if (tw, th) == (sw, sh) && desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM {
                bgra_src
            } else {
                self.scale_bgra(&bgra_src, (sw, sh), (tw, th))?
            };

            let pixels = self.read_bgra(&final_tex, tw, th)?;
            Ok((tw, th, pixels))
        })();

        unsafe {
            let _ = self.dupl.ReleaseFrame();
        }
        match extracted {
            Ok(f) => Ok(Some(f)),
            Err(_) => Err(DupErr::Other),
        }
    }

    fn scale_bgra(&mut self, src: &ID3D11Texture2D, from: (u32, u32), to: (u32, u32)) -> windows::core::Result<ID3D11Texture2D> {
        if self.vp_from != from || self.vp_to != to || self.vp.is_none() {
            let rate = DXGI_RATIONAL { Numerator: 60, Denominator: 1 };
            let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputFrameRate: rate,
                InputWidth: from.0,
                InputHeight: from.1,
                OutputFrameRate: rate,
                OutputWidth: to.0,
                OutputHeight: to.1,
                Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
            };
            let enumerator = unsafe { self.video.CreateVideoProcessorEnumerator(&content)? };
            let processor = unsafe { self.video.CreateVideoProcessor(&enumerator, 0)? };
            let out_tex = make_tex(&self.device, to.0, to.1, DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_BIND_RENDER_TARGET)?;
            let mut view = None;
            let vdesc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC { ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D, ..Default::default() };
            unsafe { self.video.CreateVideoProcessorOutputView(&out_tex, &enumerator, &vdesc, Some(&mut view))? };
            self.vp_from = from;
            self.vp_to = to;
            self.vp_enum = Some(enumerator);
            self.vp = Some(processor);
            self.vp_out = Some((out_tex, view.unwrap()));
        }
        let enumerator = self.vp_enum.as_ref().unwrap();
        let processor = self.vp.as_ref().unwrap();
        let (out_tex, out_view) = self.vp_out.as_ref().unwrap();
        let mut in_view = None;
        let idesc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC { ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D, ..Default::default() };
        unsafe {
            self.video.CreateVideoProcessorInputView(src, enumerator, &idesc, Some(&mut in_view))?;
            let mut streams = [D3D11_VIDEO_PROCESSOR_STREAM { Enable: true.into(), pInputSurface: std::mem::ManuallyDrop::new(in_view), ..Default::default() }];
            let res = self.vcontext.VideoProcessorBlt(processor, out_view, 0, &streams);
            std::mem::ManuallyDrop::drop(&mut streams[0].pInputSurface);
            res?;
        }
        Ok(out_tex.clone())
    }

    fn read_bgra(&mut self, tex: &ID3D11Texture2D, width: u32, height: u32) -> windows::core::Result<Vec<u8>> {
        let fits = self.staging.as_ref().is_some_and(|s| {
            let mut d = D3D11_TEXTURE2D_DESC::default();
            unsafe { s.GetDesc(&mut d) };
            d.Width == width && d.Height == height
        });
        if !fits {
            let d = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut made = None;
            unsafe { self.device.CreateTexture2D(&d, None, Some(&mut made))? };
            self.staging = made;
        }
        let staging = self.staging.as_ref().unwrap();
        let row_bytes = width as usize * 4;
        let mut out = vec![0u8; row_bytes * height as usize];
        unsafe {
            self.context.CopyResource(staging, tex);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
            let pitch = mapped.RowPitch as usize;
            let src = mapped.pData as *const u8;
            for y in 0..height as usize {
                std::ptr::copy_nonoverlapping(src.add(y * pitch), out.as_mut_ptr().add(y * row_bytes), row_bytes);
            }
            self.context.Unmap(staging, 0);
        }
        Ok(out)
    }
}

fn make_tex(device: &ID3D11Device, width: u32, height: u32, format: DXGI_FORMAT, bind: D3D11_BIND_FLAG) -> windows::core::Result<ID3D11Texture2D> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: format,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: bind.0 as u32,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    };
    let mut made = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut made))? };
    Ok(made.unwrap())
}

/// GDI BitBlt/StretchBlt fallback for Winlogon capture when DXGI Desktop Duplication is unavailable.
fn gdi_grab(max_w: u32, max_h: u32) -> Option<(u32, u32, Vec<u8>)> {
    let (_, rect) = main_display();
    let sw = (rect.right - rect.left).max(0) as u32;
    let sh = (rect.bottom - rect.top).max(0) as u32;
    if sw < 2 || sh < 2 {
        return None;
    }
    let (tw, th) = svc_proto::fit_even(sw, sh, max_w, max_h);
    unsafe {
        let screen_dc = GetDC(None);
        if screen_dc.is_invalid() {
            return None;
        }
        let mem_dc = CreateCompatibleDC(Some(screen_dc));
        let bmp = CreateCompatibleBitmap(screen_dc, tw as i32, th as i32);
        if mem_dc.is_invalid() || bmp.is_invalid() {
            if !bmp.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(bmp.0));
            }
            if !mem_dc.is_invalid() {
                let _ = DeleteDC(mem_dc);
            }
            let _ = ReleaseDC(None, screen_dc);
            return None;
        }
        let prev = SelectObject(mem_dc, HGDIOBJ(bmp.0));
        let _ = SetStretchBltMode(mem_dc, HALFTONE);
        let ok = StretchBlt(mem_dc, 0, 0, tw as i32, th as i32, Some(screen_dc), rect.left, rect.top, sw as i32, sh as i32, SRCCOPY).as_bool();
        let mut pixels = vec![0u8; (tw as usize) * (th as usize) * 4];
        let mut got = false;
        if ok {
            let mut bmi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: tw as i32,
                    biHeight: -(th as i32), // top-down BGRA
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let lines = GetDIBits(mem_dc, bmp, 0, th, Some(pixels.as_mut_ptr() as *mut _), &mut bmi, DIB_RGB_COLORS);
            got = lines > 0;
        }
        let _ = SelectObject(mem_dc, prev);
        let _ = DeleteObject(HGDIOBJ(bmp.0));
        let _ = DeleteDC(mem_dc);
        let _ = ReleaseDC(None, screen_dc);
        got.then_some((tw, th, pixels))
    }
}
