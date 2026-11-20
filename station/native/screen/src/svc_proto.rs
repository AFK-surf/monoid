// Wire protocol and security helpers shared between stillfail-screen (user session) and stillfail-screen-svc
// (LocalSystem service + active-session SYSTEM worker).
//
// Each pipe connection carries framed messages: 1 byte kind + 4 bytes big-endian payload length + payload.
//   1 HELLO     C->W: {"version":1,"input":bool,"capture":bool,"maxWidth"?:u32,"maxHeight"?:u32}
//               W->C: {"version":1,"ok":true,"desktop":"Default"|"Winlogon","secure":bool,"session":u32}
//   2 INPUT     C->W: win-input JSON op (mouse, wheel, key, text, paste, nudge, sas)
//   3 DESKTOP   W->C: {"name":"Default"|"Winlogon","secure":bool}
//   4 FRAME_REQ C->W: {"maxWidth":u32,"maxHeight":u32}
//   5 FRAME     W->C: [width:u32 BE][height:u32 BE][ts_us:i64 BE][bgra: width*height*4]
//   6 CURSOR    W->C: {"x":f64,"y":f64,"shape":str}
use std::io::{self, ErrorKind, Read, Write};

pub const SERVICE_NAME: &str = "StillfailScreenService";
pub const SERVICE_DISPLAY_NAME: &str = "still.fail Screen Service";
pub const SERVICE_DESCRIPTION: &str = "Allows still.fail remote screens to interact with UAC prompts, elevated windows, and the lock screen.";
pub const PIPE_NAME: &str = r"\\.\pipe\stillfail-screen-svc-v1";
pub const INSTALL_DIR: &str = r"C:\Program Files\still.fail\screen-service";
pub const INSTALL_EXE: &str = "stillfail-screen-svc.exe";
pub const REG_SUBKEY: &str = r"SOFTWARE\still.fail\ScreenService";
pub const REG_USER_SID: &str = "AllowedUserSid";
pub const REG_VERSION: &str = "Version";
pub const PROTO_VERSION: u32 = 1;

/// Upper bound on any framed pipe message (4K BGRA = 33.2 MiB; 64 MiB leaves headroom without unbounded allocation).
pub const MAX_MSG_BYTES: usize = 64 * 1024 * 1024;
/// Upper bound on small JSON control/input messages.
pub const MAX_CONTROL_BYTES: usize = 1024 * 1024;

pub const KIND_HELLO: u8 = 1;
pub const KIND_INPUT: u8 = 2;
pub const KIND_DESKTOP: u8 = 3;
pub const KIND_FRAME_REQ: u8 = 4;
pub const KIND_FRAME: u8 = 5;
pub const KIND_CURSOR: u8 = 6;

pub fn write_msg(w: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_MSG_BYTES {
        return Err(io::Error::new(ErrorKind::InvalidInput, "message exceeds limit"));
    }
    let mut head = [0u8; 5];
    head[0] = kind;
    head[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&head)?;
    if !payload.is_empty() {
        w.write_all(payload)?;
    }
    w.flush()
}

pub fn write_json(w: &mut impl Write, kind: u8, value: &serde_json::Value) -> io::Result<()> {
    write_msg(w, kind, value.to_string().as_bytes())
}

pub fn read_msg(r: &mut impl Read, limit: usize) -> io::Result<Option<(u8, Vec<u8>)>> {
    let mut head = [0u8; 5];
    match r.read_exact(&mut head) {
        Ok(()) => {}
        Err(e) if e.kind() == ErrorKind::UnexpectedEof || e.kind() == ErrorKind::BrokenPipe => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if len > limit {
        return Err(io::Error::new(ErrorKind::InvalidData, "message exceeds limit"));
    }
    let mut payload = vec![0u8; len];
    if len > 0 {
        r.read_exact(&mut payload)?;
    }
    Ok(Some((head[0], payload)))
}

/// Whether Windows' active input desktop is isolated from the user's normal desktop (Winlogon UAC / lock screen / screensaver).
pub fn is_secure_desktop(name: &str) -> bool {
    let trimmed = name.trim();
    !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case("Default")
}

/// Validates a canonical Windows SID string (`S-1-...`) before interpolating it into an SDDL string.
pub fn is_valid_sid(sid: &str) -> bool {
    if sid.len() < 7 || sid.len() > 128 {
        return false;
    }
    let Some(rest) = sid.strip_prefix("S-1-") else {
        return false;
    };
    let mut parts = rest.split('-');
    let Some(first) = parts.next() else {
        return false;
    };
    if first.is_empty() || !first.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    let mut count = 1usize;
    for part in parts {
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        count += 1;
    }
    count >= 2
}

/// Pipe DACL: SYSTEM full, Administrators full, owning user SID read/write only (no WRITE_DAC/WRITE_OWNER).
pub fn pipe_sddl(user_sid: &str) -> Option<String> {
    if !is_valid_sid(user_sid) {
        return None;
    }
    Some(format!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;{user_sid})"))
}

/// Install directory DACL: SYSTEM full, Administrators full, Authenticated Users read/execute only.
pub fn dir_sddl() -> &'static str {
    "D:P(A;OICI;GA;;;SY)(A;OICI;GA;;;BA)(A;OICI;GRGX;;;AU)"
}

/// Whether the connecting process image path is one of our own screen binaries.
pub fn is_allowed_client_exe(path: &str) -> bool {
    let base = path.rsplit(['\\', '/']).next().unwrap_or("");
    base.eq_ignore_ascii_case("stillfail-screen.exe") || base.eq_ignore_ascii_case("stillfail-screen-svc.exe")
}

/// Packs a BGRA frame into KIND_FRAME's payload: [width:4][height:4][ts_us:8][bgra].
pub fn encode_frame_payload(width: u32, height: u32, ts: i64, bgra: &[u8]) -> Option<Vec<u8>> {
    let expected = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
    if width == 0 || height == 0 || bgra.len() != expected || 16 + expected > MAX_MSG_BYTES {
        return None;
    }
    let mut out = Vec::with_capacity(16 + expected);
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&ts.to_be_bytes());
    out.extend_from_slice(bgra);
    Some(out)
}

/// Unpacks KIND_FRAME's payload into (width, height, ts_us, bgra).
pub fn decode_frame_payload(payload: &[u8]) -> Option<(u32, u32, i64, &[u8])> {
    if payload.len() < 16 {
        return None;
    }
    let width = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    let height = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
    let ts = i64::from_be_bytes([payload[8], payload[9], payload[10], payload[11], payload[12], payload[13], payload[14], payload[15]]);
    let expected = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
    if width == 0 || height == 0 || payload.len() != 16 + expected {
        return None;
    }
    Some((width, height, ts, &payload[16..]))
}

/// Scales (src_w, src_h) down to fit within (max_w, max_h), keeping aspect ratio and even dimensions (>= 2).
pub fn fit_even(src_w: u32, src_h: u32, max_w: u32, max_h: u32) -> (u32, u32) {
    let (sw, sh) = (src_w.max(2) as f64, src_h.max(2) as f64);
    let (mw, mh) = (max_w.max(16) as f64, max_h.max(16) as f64);
    let scale = (mw / sw).min(mh / sh).min(1.0);
    let even = |v: f64| ((v.round() as u32) & !1).max(2);
    (even(sw * scale), even(sh * scale))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_framed_messages() {
        let mut buf = Vec::new();
        write_json(&mut buf, KIND_HELLO, &serde_json::json!({ "version": PROTO_VERSION, "input": true })).unwrap();
        write_msg(&mut buf, KIND_FRAME_REQ, b"{}").unwrap();
        let mut cur = &buf[..];
        let (k1, p1) = read_msg(&mut cur, MAX_CONTROL_BYTES).unwrap().unwrap();
        assert_eq!(k1, KIND_HELLO);
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&p1).unwrap()["version"], PROTO_VERSION);
        let (k2, p2) = read_msg(&mut cur, MAX_CONTROL_BYTES).unwrap().unwrap();
        assert_eq!(k2, KIND_FRAME_REQ);
        assert_eq!(p2, b"{}");
        assert_eq!(read_msg(&mut cur, MAX_CONTROL_BYTES).unwrap(), None);
    }

    #[test]
    fn rejects_oversized_messages() {
        let bad = [KIND_FRAME, 0x05, 0x00, 0x00, 0x00]; // 80 MiB
        let err = read_msg(&mut &bad[..], MAX_MSG_BYTES).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidData);
    }

    #[test]
    fn classifies_secure_desktops() {
        assert!(!is_secure_desktop("Default"));
        assert!(!is_secure_desktop("default"));
        assert!(!is_secure_desktop(""));
        assert!(is_secure_desktop("Winlogon"));
        assert!(is_secure_desktop("Screen-saver"));
    }

    #[test]
    fn validates_sids_and_builds_sddl() {
        let sid = "S-1-5-21-3623811015-3361044348-30300820-1001";
        assert!(is_valid_sid(sid));
        assert_eq!(pipe_sddl(sid).unwrap(), format!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;{sid})"));
        assert!(!is_valid_sid("S-1-5-21)(A;;GA;;;WD"));
        assert!(!is_valid_sid("S-1-5"));
        assert!(!is_valid_sid(""));
        assert!(pipe_sddl("invalid").is_none());
    }

    #[test]
    fn checks_allowed_client_executables() {
        assert!(is_allowed_client_exe(r"C:\Users\pengx\.stillfail\app\station\stillfail-screen.exe"));
        assert!(is_allowed_client_exe(r"C:\Program Files\still.fail\screen-service\STILLFAIL-SCREEN-SVC.EXE"));
        assert!(!is_allowed_client_exe(r"C:\Windows\System32\cmd.exe"));
        assert!(!is_allowed_client_exe(r"C:\evil\fake-stillfail-screen.exe"));
    }

    #[test]
    fn round_trips_frame_payload() {
        let bgra = vec![0xABu8; 4 * 2 * 4];
        let packed = encode_frame_payload(4, 2, 123456, &bgra).unwrap();
        let (w, h, ts, pixels) = decode_frame_payload(&packed).unwrap();
        assert_eq!((w, h, ts), (4, 2, 123456));
        assert_eq!(pixels, &bgra[..]);
        assert!(decode_frame_payload(&packed[..packed.len() - 1]).is_none());
        assert!(encode_frame_payload(0, 2, 0, &[]).is_none());
    }

    #[test]
    fn fits_even_dimensions() {
        assert_eq!(fit_even(3840, 2160, 1920, 1080), (1920, 1080));
        assert_eq!(fit_even(1920, 1080, 3840, 2160), (1920, 1080));
        assert_eq!(fit_even(1366, 768, 1280, 720), (1280, 720));
    }
}
