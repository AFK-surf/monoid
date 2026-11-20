// Client bridge inside stillfail-screen.exe to stillfail-screen-svc.exe:
// - ServiceInput: forwards human remote input (mouse, wheel, key, text, paste, nudge, sas) to the SYSTEM worker so
//   UAC prompts, elevated windows (UIPI), and lock screens respond; transparently falls back to local SendInput when
//   the service is not installed or unavailable. Never enabled for agent views.
// - ServiceCapture: watches desktop switches (Default <-> Winlogon) and pulls BGRA frames + live cursor from the
//   SYSTEM worker whenever Windows is on a secure desktop (UAC or lock screen).
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
    mpsc::Sender,
};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Out;
use super::input::Input;
use super::svc_pipe::{self, PipeHandle, PipeWriter};
use super::svc_proto::{
    self, KIND_CURSOR, KIND_DESKTOP, KIND_FRAME, KIND_FRAME_REQ, KIND_HELLO, KIND_INPUT, MAX_CONTROL_BYTES,
    MAX_MSG_BYTES, PIPE_NAME, PROTO_VERSION,
};
use super::view::Msg;

const RECONNECT_BACKOFF: Duration = Duration::from_secs(2);

pub struct ServiceInput {
    allowed: bool,
    local: Input,
    writer: Option<PipeWriter>,
    handle: Option<Arc<PipeHandle>>,
    retry_after: Option<Instant>,
    out: Out,
}

impl ServiceInput {
    pub fn new(allowed: bool, out: Out) -> Self {
        let mut this = Self { allowed, local: Input::new(), writer: None, handle: None, retry_after: None, out };
        if allowed {
            this.try_connect();
        }
        this
    }

    fn try_connect(&mut self) {
        if !self.allowed {
            return;
        }
        let Ok(handle) = svc_pipe::connect(PIPE_NAME) else {
            self.retry_after = Some(Instant::now() + RECONNECT_BACKOFF);
            return;
        };
        let Ok((mut reader, mut writer)) = svc_pipe::split(handle.clone()) else {
            self.retry_after = Some(Instant::now() + RECONNECT_BACKOFF);
            return;
        };
        let hello = json!({ "version": PROTO_VERSION, "input": true, "capture": false });
        if svc_proto::write_json(&mut writer, KIND_HELLO, &hello).is_err() {
            self.retry_after = Some(Instant::now() + RECONNECT_BACKOFF);
            return;
        }
        match svc_proto::read_msg(&mut reader, MAX_CONTROL_BYTES) {
            Ok(Some((KIND_HELLO, payload))) => {
                if let Ok(ack) = serde_json::from_slice::<Value>(&payload) {
                    if ack["ok"].as_bool() == Some(true) {
                        self.writer = Some(writer);
                        self.handle = Some(handle);
                        self.retry_after = None;
                        self.out.json(4, json!({ "serviceInput": true }));
                        return;
                    }
                }
            }
            _ => {}
        }
        self.retry_after = Some(Instant::now() + RECONNECT_BACKOFF);
    }

    fn send_or_fallback(&mut self, op: &Value) -> bool {
        if self.writer.is_none() && self.allowed {
            if self.retry_after.is_some_and(|t| Instant::now() >= t) {
                self.try_connect();
            }
        }
        if let Some(writer) = self.writer.as_mut() {
            if svc_proto::write_json(writer, KIND_INPUT, op).is_ok() {
                return true;
            }
            self.writer = None;
            if let Some(h) = self.handle.take() {
                h.cancel();
            }
            self.retry_after = Some(Instant::now() + RECONNECT_BACKOFF);
            self.out.json(4, json!({ "serviceInput": false }));
        }
        false
    }

    pub fn post(&mut self, op: &Value) {
        if !self.send_or_fallback(op) {
            self.local.post(op);
        }
    }

    pub fn paste(&mut self) {
        if !self.send_or_fallback(&json!({ "op": "paste" })) {
            self.local.paste();
        }
    }

    pub fn nudge(&mut self) {
        if !self.send_or_fallback(&json!({ "op": "nudge" })) {
            self.local.nudge();
        }
    }
}

impl Drop for ServiceInput {
    fn drop(&mut self) {
        if let Some(h) = self.handle.take() {
            h.cancel();
        }
    }
}

pub struct ServiceCapture {
    handle: Arc<PipeHandle>,
    writer: Mutex<PipeWriter>,
}

impl ServiceCapture {
    /// Connects to stillfail-screen-svc for desktop-switch notifications and Winlogon frame fallback.
    /// Returns `(client, initial_secure, initial_desktop_name)` if the service is running.
    pub fn connect(max_w: u32, max_h: u32, tx: Sender<Msg>, out: Out, send_cursor: bool) -> Option<(Self, bool, String)> {
        let handle = svc_pipe::connect(PIPE_NAME).ok()?;
        let (mut reader, mut writer) = svc_pipe::split(handle.clone()).ok()?;
        let hello = json!({
            "version": PROTO_VERSION,
            "input": false,
            "capture": true,
            "maxWidth": max_w,
            "maxHeight": max_h,
        });
        svc_proto::write_json(&mut writer, KIND_HELLO, &hello).ok()?;
        let (KIND_HELLO, payload) = svc_proto::read_msg(&mut reader, MAX_CONTROL_BYTES).ok()?? else {
            return None;
        };
        let ack: Value = serde_json::from_slice(&payload).ok()?;
        if ack["ok"].as_bool() != Some(true) {
            return None;
        }
        let desktop = ack["desktop"].as_str().unwrap_or("Default").to_string();
        let initial_secure = ack["secure"].as_bool().unwrap_or_else(|| svc_proto::is_secure_desktop(&desktop));
        let secure = Arc::new(AtomicBool::new(initial_secure));
        let secure_bg = secure.clone();
        let _ = std::thread::Builder::new().name("svc-capture-read".into()).spawn(move || {
            while let Ok(Some((kind, payload))) = svc_proto::read_msg(&mut reader, MAX_MSG_BYTES) {
                match kind {
                    KIND_DESKTOP => {
                        if let Ok(v) = serde_json::from_slice::<Value>(&payload) {
                            let name = v["name"].as_str().unwrap_or("Default").to_string();
                            let is_sec = v["secure"].as_bool().unwrap_or_else(|| svc_proto::is_secure_desktop(&name));
                            secure_bg.store(is_sec, Ordering::Relaxed);
                            if tx.send(Msg::SecureDesktop(is_sec, name)).is_err() {
                                break;
                            }
                        }
                    }
                    KIND_FRAME => {
                        if let Some((width, height, _ts, pixels)) = svc_proto::decode_frame_payload(&payload) {
                            if tx.send(Msg::ServiceFrame { width, height, bgra: pixels.to_vec() }).is_err() {
                                break;
                            }
                        }
                    }
                    KIND_CURSOR => {
                        if send_cursor && secure_bg.load(Ordering::Relaxed) {
                            out.send(6, &payload);
                        }
                    }
                    _ => {}
                }
            }
            secure_bg.store(false, Ordering::Relaxed);
            let _ = tx.send(Msg::ServiceGone);
        });
        Some((Self { handle, writer: Mutex::new(writer) }, initial_secure, desktop))
    }

    pub fn request_frame(&self, max_w: u32, max_h: u32) -> bool {
        let Ok(mut w) = self.writer.lock() else {
            return false;
        };
        svc_proto::write_json(&mut *w, KIND_FRAME_REQ, &json!({ "maxWidth": max_w, "maxHeight": max_h })).is_ok()
    }
}

impl Drop for ServiceCapture {
    fn drop(&mut self) {
        self.handle.cancel();
    }
}
