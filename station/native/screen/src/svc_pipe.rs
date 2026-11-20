// Full-duplex overlapped Windows Named Pipe wrapper shared by stillfail-screen and stillfail-screen-svc.
// Using FILE_FLAG_OVERLAPPED with independent read/write events lets one thread read frames/events while another
// thread writes requests without blocking each other, and lets shutdown unblock pending I/O via CancelIoEx.
use std::io::{self, Read, Write};
use std::sync::Arc;

use windows::Win32::Foundation::{
    CloseHandle, ERROR_IO_PENDING, ERROR_PIPE_BUSY, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_OVERLAPPED, FILE_SHARE_NONE, OPEN_EXISTING, ReadFile, WriteFile,
};
use windows::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows::Win32::System::Pipes::WaitNamedPipeW;
use windows::Win32::System::Threading::CreateEventW;
use windows::core::HSTRING;

pub struct PipeHandle(HANDLE);

unsafe impl Send for PipeHandle {}
unsafe impl Sync for PipeHandle {}

impl PipeHandle {
    pub fn from_raw(handle: HANDLE) -> Arc<Self> {
        Arc::new(PipeHandle(handle))
    }

    pub fn raw(&self) -> HANDLE {
        self.0
    }

    pub fn cancel(&self) {
        unsafe {
            let _ = CancelIoEx(self.0, None);
        }
    }
}

impl Drop for PipeHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() && self.0 != INVALID_HANDLE_VALUE {
            unsafe {
                let _ = CancelIoEx(self.0, None);
                let _ = CloseHandle(self.0);
            }
        }
    }
}

pub struct PipeReader {
    handle: Arc<PipeHandle>,
    event: HANDLE,
}

unsafe impl Send for PipeReader {}

impl Drop for PipeReader {
    fn drop(&mut self) {
        if !self.event.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.event);
            }
        }
    }
}

pub struct PipeWriter {
    handle: Arc<PipeHandle>,
    event: HANDLE,
}

unsafe impl Send for PipeWriter {}

impl Drop for PipeWriter {
    fn drop(&mut self) {
        if !self.event.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.event);
            }
        }
    }
}

pub fn split(handle: Arc<PipeHandle>) -> io::Result<(PipeReader, PipeWriter)> {
    let read_event = unsafe { CreateEventW(None, true, false, None) }.map_err(win_err)?;
    let write_event = match unsafe { CreateEventW(None, true, false, None) } {
        Ok(e) => e,
        Err(e) => {
            unsafe {
                let _ = CloseHandle(read_event);
            }
            return Err(win_err(e));
        }
    };
    Ok((
        PipeReader { handle: handle.clone(), event: read_event },
        PipeWriter { handle, event: write_event },
    ))
}

/// Connects to `pipe_name` with FILE_FLAG_OVERLAPPED. Returns Err(NotFound) immediately if the service is not running.
pub fn connect(pipe_name: &str) -> io::Result<Arc<PipeHandle>> {
    let wide = HSTRING::from(pipe_name);
    for attempt in 0..3 {
        let res = unsafe {
            CreateFileW(
                &wide,
                GENERIC_READ.0 | GENERIC_WRITE.0,
                FILE_SHARE_NONE,
                None,
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                None,
            )
        };
        match res {
            Ok(h) if !h.is_invalid() && h != INVALID_HANDLE_VALUE => return Ok(PipeHandle::from_raw(h)),
            Ok(_) => return Err(io::Error::new(io::ErrorKind::Other, "invalid pipe handle")),
            Err(e) => {
                let code = e.code().0 as u32 & 0xFFFF;
                if code == ERROR_PIPE_BUSY.0 && attempt < 2 {
                    unsafe {
                        let _ = WaitNamedPipeW(&wide, 300);
                    }
                    continue;
                }
                return Err(win_err(e));
            }
        }
    }
    Err(io::Error::new(io::ErrorKind::TimedOut, "pipe busy"))
}

impl Read for PipeReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let mut ov = OVERLAPPED { hEvent: self.event, ..Default::default() };
        let mut got = 0u32;
        let ok = unsafe { ReadFile(self.handle.raw(), Some(buf), Some(&mut got), Some(&mut ov)) };
        match ok {
            Ok(()) => Ok(got as usize),
            Err(e) if (e.code().0 as u32 & 0xFFFF) == ERROR_IO_PENDING.0 => {
                let mut transferred = 0u32;
                unsafe { GetOverlappedResult(self.handle.raw(), &ov, &mut transferred, true) }.map_err(win_err)?;
                Ok(transferred as usize)
            }
            Err(e) => Err(win_err(e)),
        }
    }
}

impl Write for PipeWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let mut ov = OVERLAPPED { hEvent: self.event, ..Default::default() };
        let mut written = 0u32;
        let ok = unsafe { WriteFile(self.handle.raw(), Some(buf), Some(&mut written), Some(&mut ov)) };
        match ok {
            Ok(()) => Ok(written as usize),
            Err(e) if (e.code().0 as u32 & 0xFFFF) == ERROR_IO_PENDING.0 => {
                let mut transferred = 0u32;
                unsafe { GetOverlappedResult(self.handle.raw(), &ov, &mut transferred, true) }.map_err(win_err)?;
                Ok(transferred as usize)
            }
            Err(e) => Err(win_err(e)),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub fn win_err(e: windows::core::Error) -> io::Error {
    let raw = e.code().0 as u32;
    let code = if (raw & 0xFFFF_0000) == 0x8007_0000 { (raw & 0xFFFF) as i32 } else { raw as i32 };
    io::Error::from_raw_os_error(code)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::svc_proto::{KIND_FRAME, KIND_FRAME_REQ, KIND_HELLO, MAX_CONTROL_BYTES, MAX_MSG_BYTES, read_msg, write_json, write_msg};
    use windows::Win32::Foundation::ERROR_PIPE_CONNECTED;
    use windows::Win32::Storage::FileSystem::PIPE_ACCESS_DUPLEX;
    use windows::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
    };

    #[test]
    fn full_duplex_overlapped_pipe_reads_and_writes_concurrently() {
        let name = format!(r"\\.\pipe\stillfail-screen-test-{}", std::process::id());
        let wide = HSTRING::from(&name);
        let server_raw = unsafe {
            CreateNamedPipeW(
                &wide,
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                64 * 1024,
                64 * 1024,
                0,
                None,
            )
        };
        assert!(!server_raw.is_invalid() && server_raw != INVALID_HANDLE_VALUE);
        let server = PipeHandle::from_raw(server_raw);
        let server_bg = server.clone();

        let srv_thread = std::thread::spawn(move || {
            let ev = unsafe { CreateEventW(None, true, false, None) }.unwrap();
            let mut ov = OVERLAPPED { hEvent: ev, ..Default::default() };
            match unsafe { ConnectNamedPipe(server_bg.raw(), Some(&mut ov)) } {
                Ok(()) => {}
                Err(e) if (e.code().0 as u32 & 0xFFFF) == ERROR_PIPE_CONNECTED.0 => {}
                Err(e) if (e.code().0 as u32 & 0xFFFF) == ERROR_IO_PENDING.0 => {
                    let mut dummy = 0u32;
                    unsafe { GetOverlappedResult(server_bg.raw(), &ov, &mut dummy, true) }.unwrap();
                }
                Err(e) => panic!("ConnectNamedPipe: {e}"),
            }
            unsafe {
                let _ = CloseHandle(ev);
            }
            let (mut r, mut w) = split(server_bg).unwrap();
            let (k, p) = read_msg(&mut r, MAX_CONTROL_BYTES).unwrap().unwrap();
            assert_eq!(k, KIND_HELLO);
            assert_eq!(serde_json::from_slice::<serde_json::Value>(&p).unwrap()["version"], 1);
            write_json(&mut w, KIND_HELLO, &serde_json::json!({ "ok": true })).unwrap();

            // Wait for frame request while client is simultaneously blocked in ReadFile.
            let (k2, _) = read_msg(&mut r, MAX_CONTROL_BYTES).unwrap().unwrap();
            assert_eq!(k2, KIND_FRAME_REQ);
            write_msg(&mut w, KIND_FRAME, &[1, 2, 3, 4]).unwrap();
        });

        let client = connect(&name).unwrap();
        let (mut cr, mut cw) = split(client.clone()).unwrap();
        write_json(&mut cw, KIND_HELLO, &serde_json::json!({ "version": 1 })).unwrap();
        let (k, p) = read_msg(&mut cr, MAX_CONTROL_BYTES).unwrap().unwrap();
        assert_eq!(k, KIND_HELLO);
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&p).unwrap()["ok"], true);

        // Start a blocking reader on another thread FIRST, then write KIND_FRAME_REQ on main thread:
        // a synchronous pipe would deadlock here; overlapped pipe completes cleanly.
        let rd_thread = std::thread::spawn(move || read_msg(&mut cr, MAX_MSG_BYTES).unwrap().unwrap());
        std::thread::sleep(std::time::Duration::from_millis(20));
        write_json(&mut cw, KIND_FRAME_REQ, &serde_json::json!({ "maxWidth": 640, "maxHeight": 360 })).unwrap();
        let (fk, fp) = rd_thread.join().unwrap();
        assert_eq!(fk, KIND_FRAME);
        assert_eq!(fp, vec![1, 2, 3, 4]);
        srv_thread.join().unwrap();
    }
}
