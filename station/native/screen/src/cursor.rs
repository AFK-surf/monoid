// The pointer, said beside a video's pictures (which leave it out: capture.rs) as message 6 {x, y, shape}: where it is on
// the main display (0..1) and its shape as CSS names it (the system's standard cursors; an app's own "custom:<id>", its
// picture said first as message 11 once a process: cursor_image.rs; any other "default"), looked at 60 times a second
// and said as it changes, for as long as the view's process lasts.
use std::collections::HashSet;
use std::time::Duration;

use serde_json::json;
use windows::Win32::Foundation::POINT;
use windows::Win32::Graphics::Gdi::{DeleteObject, HGDIOBJ};
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx};
use windows::Win32::UI::HiDpi::GetDpiForSystem;
use windows::Win32::UI::WindowsAndMessaging::{
    CURSOR_SHOWING, CURSORINFO, GetCursorInfo, GetIconInfo, HCURSOR, HICON, ICONINFO, IDC_APPSTARTING, IDC_ARROW, IDC_CROSS, IDC_HAND, IDC_IBEAM, IDC_NO,
    IDC_SIZEALL, IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE, IDC_WAIT, LoadCursorW,
};

use super::Out;
use super::cursor_image;
use super::image::Images;
use super::view::main_display;

/// The most pictures said before they are said again.
const SAID_MOST: usize = 64;

/// The system's cursors (shared handles: the same in every app that shows one) by their CSS names.
fn shapes() -> Vec<(HCURSOR, &'static str)> {
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

/// The masks and colours GetIconInfo makes for its caller, deleted as it goes.
struct IconBitmaps(ICONINFO);

impl Drop for IconBitmaps {
    fn drop(&mut self) {
        for bitmap in [self.0.hbmMask, self.0.hbmColor] {
            if !bitmap.is_invalid() {
                let _ = unsafe { DeleteObject(HGDIOBJ(bitmap.0)) };
            }
        }
    }
}

/// A pointer of an app's own: its id and message 11's payload; none where it cannot be read or is too large.
fn custom(images: &Images, cursor: HCURSOR) -> Option<(String, Vec<u8>)> {
    let icon = HICON(cursor.0);
    let mut info = ICONINFO::default();
    unsafe { GetIconInfo(icon, &mut info) }.ok()?;
    let info = IconBitmaps(info);
    let (width, height, pixels, png) = images.cursor(icon).ok()?;
    let scale = unsafe { GetDpiForSystem() } as f64 / 96.0;
    let head = cursor_image::points((width, height), (info.0.xHotspot, info.0.yHotspot), scale)?;
    cursor_image::payload(head, &pixels, &png)
}

/// Says the pointer as it moves or changes, on a thread of its own, until the process ends.
pub fn follow(out: Out) {
    std::thread::spawn(move || {
        let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        let images = Images::new().ok();
        let shapes = shapes();
        let mut said = String::new();
        // The handle looked at last and what it is (read again only as the handle changes), and the pictures said.
        let mut seen: Option<(HCURSOR, String, Option<(String, Vec<u8>)>)> = None;
        let mut pictures: HashSet<String> = HashSet::new();
        loop {
            let mut info = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
            if unsafe { GetCursorInfo(&mut info) }.is_ok() {
                let (_, rect) = main_display();
                let (w, h) = ((rect.right - rect.left).max(1) as f64, (rect.bottom - rect.top).max(1) as f64);
                let POINT { x, y } = info.ptScreenPos;
                let unit = |v: f64| (v.clamp(0.0, 1.0) * 10000.0).round() / 10000.0;
                // Hidden (a game, a video player full screen): none drawn.
                let shape = if info.flags.0 & CURSOR_SHOWING.0 == 0 {
                    "none".to_string()
                } else {
                    if seen.as_ref().map(|s| s.0) != Some(info.hCursor) {
                        let (name, picture) = match shapes.iter().find(|(c, _)| *c == info.hCursor) {
                            Some((_, n)) => (n.to_string(), None),
                            None => match images.as_ref().and_then(|images| custom(images, info.hCursor)) {
                                Some((id, payload)) => (format!("custom:{id}"), Some((id, payload))),
                                None => ("default".to_string(), None),
                            },
                        };
                        seen = Some((info.hCursor, name, picture));
                    }
                    seen.as_ref().map(|s| s.1.clone()).unwrap_or_default()
                };
                let now = json!({ "x": unit((x - rect.left) as f64 / w), "y": unit((y - rect.top) as f64 / h), "shape": shape }).to_string();
                if now != said {
                    let picture = seen.as_ref().and_then(|s| s.2.as_ref()).filter(|(id, _)| shape.starts_with("custom:") && !pictures.contains(id));
                    if let Some((id, payload)) = picture {
                        if pictures.len() >= SAID_MOST {
                            pictures.clear();
                        }
                        pictures.insert(id.clone());
                        out.send(11, payload);
                    }
                    out.send(6, now.as_bytes());
                    said = now;
                }
            }
            std::thread::sleep(Duration::from_millis(16));
        }
    });
}
