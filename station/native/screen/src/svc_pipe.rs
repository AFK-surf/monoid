// Full-duplex overlapped Windows Named Pipe wrapper shared by stillfail-screen and stillfail-screen-svc.
// Using FILE_FLAG_OVERLAPPED with independent read/write events lets one thread read frames/events while another
// thread writes requests without blocking each other, and lets shutdown unblock pending I/O via CancelIoEx.
use std::io::{self, Read, Write};
use std::sync::Arc;

use windows::Win32::Foundation::{
    CloseHandle, ERROR_IO_PENDING, ERROR_PIPE_BUSY, ERROR_SUCCESS, HANDLE, HLOCAL, INVALID_HANDLE_VALUE, LocalFree,
};
use windows::Win32::Security::Authorization::{GetSecurityInfo, SE_KERNEL_OBJECT};
use windows::Win32::Security::{
    IsWellKnownSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, WinBuiltinAdministratorsSid, WinLocalSystemSid,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_OVERLAPPED, FILE_GENERIC_READ, FILE_SHARE_NONE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA,
    OPEN_EXISTING, ReadFile, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT, WriteFile,
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

/// Connects to the service's pipe `pipe_name` with FILE_FLAG_OVERLAPPED. Returns Err(NotFound) immediately if the
/// service is not running, and Err(PermissionDenied) if the pipe under that name is not the worker's (another
/// process took the name first: `pipe_owned_by_privileged`).
pub fn connect(pipe_name: &str) -> io::Result<Arc<PipeHandle>> {
    let handle = open(pipe_name)?;
    // Dropping `handle` on refusal closes it once.
    pipe_owned_by_privileged(handle.raw())?;
    Ok(handle)
}

/// Whether the pipe's owner is LocalSystem or Administrators: the worker's pipe is LocalSystem's (svc_proto.rs
/// `pipe_sddl` `O:SY`), a worker installed before that is Administrators' (a LocalSystem token's default owner). A
/// limited user cannot make either the owner of a pipe it creates. Read from the handle's own security descriptor
/// (the client's access and a server handle both include READ_CONTROL), so it works for a limited user who cannot
/// open the worker's process or token. Err(PermissionDenied) for another owner; the OS error when it cannot be read.
pub(crate) fn pipe_owned_by_privileged(handle: HANDLE) -> io::Result<()> {
    let mut owner = PSID::default();
    let mut sd = PSECURITY_DESCRIPTOR::default();
    let rc = unsafe {
        GetSecurityInfo(handle, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION, Some(&mut owner), None, None, None, Some(&mut sd))
    };
    if rc != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(rc.0 as i32));
    }
    let privileged = !owner.is_invalid()
        && unsafe { IsWellKnownSid(owner, WinLocalSystemSid).as_bool() || IsWellKnownSid(owner, WinBuiltinAdministratorsSid).as_bool() };
    if !sd.0.is_null() {
        unsafe {
            let _ = LocalFree(Some(HLOCAL(sd.0)));
        }
    }
    if privileged {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::PermissionDenied, "pipe is not owned by LocalSystem or Administrators"))
    }
}

/// Opens `pipe_name` with FILE_FLAG_OVERLAPPED, without checking who serves it. Identification-level impersonation
/// only, so a server that is not the worker (refused by `connect` right after) cannot act as this user meanwhile. It
/// asks for reading, writing and READ_CONTROL only: GENERIC_WRITE would also ask FILE_CREATE_PIPE_INSTANCE, which the
/// pipe's DACL gives the user no more (svc_proto.rs `pipe_sddl`).
fn open(pipe_name: &str) -> io::Result<Arc<PipeHandle>> {
    let wide = HSTRING::from(pipe_name);
    for attempt in 0..3 {
        let res = unsafe {
            CreateFileW(
                &wide,
                FILE_GENERIC_READ.0 | FILE_WRITE_DATA.0 | FILE_WRITE_ATTRIBUTES.0,
                FILE_SHARE_NONE,
                None,
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
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

    /// This process's user's SID as a string (`S-1-5-21-…`).
    fn own_user_sid() -> (String, bool) {
        use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
        use windows::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
        use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
        unsafe {
            let mut token = HANDLE::default();
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).unwrap();
            let mut buf = vec![0u64; 128];
            let mut len = 0u32;
            GetTokenInformation(token, TokenUser, Some(buf.as_mut_ptr().cast()), (buf.len() * 8) as u32, &mut len).unwrap();
            let _ = CloseHandle(token);
            let user = &*(buf.as_ptr() as *const TOKEN_USER);
            let system = IsWellKnownSid(user.User.Sid, WinLocalSystemSid).as_bool();
            let mut text = windows::core::PWSTR::null();
            ConvertSidToStringSidW(user.User.Sid, &mut text).unwrap();
            let sid = text.to_string().unwrap();
            let _ = LocalFree(Some(HLOCAL(text.0.cast())));
            (sid, system)
        }
    }

    #[test]
    fn refuses_a_pipe_owned_by_an_ordinary_user() {
        use windows::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
        use windows::Win32::Security::SECURITY_ATTRIBUTES;
        let (sid, system) = own_user_sid();
        if system {
            eprintln!("skipped: runs as LocalSystem, which owns every pipe it makes");
            return;
        }
        // Owned by this test's user, as one a limited user made under the service's name would be. Explicit, as an
        // elevated test's default owner is Administrators.
        let mut sd = PSECURITY_DESCRIPTOR::default();
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(&HSTRING::from(format!("O:{sid}D:P(A;;GA;;;WD)")), SDDL_REVISION_1, &mut sd, None)
                .unwrap();
        }
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: false.into(),
        };
        let name = format!(r"\\.\pipe\stillfail-screen-test-owner-{}", std::process::id());
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
                Some(&sa),
            )
        };
        unsafe {
            let _ = LocalFree(Some(HLOCAL(sd.0)));
        }
        assert!(!server_raw.is_invalid() && server_raw != INVALID_HANDLE_VALUE);
        let server = PipeHandle::from_raw(server_raw);
        // The worker's own check of its server handle refuses it too.
        let err = pipe_owned_by_privileged(server.raw()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
        assert!(err.to_string().contains("not owned by"), "{err}");
        let err = connect(&name).err().expect("a user's pipe is refused");
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
        assert!(err.to_string().contains("not owned by"), "{err}");
    }

    #[test]
    fn the_users_access_opens_the_pipe_but_adds_no_instance() {
        use crate::svc_proto::PIPE_USER_ACCESS;
        use windows::Win32::Foundation::{ERROR_ACCESS_DENIED, GetLastError};
        use windows::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
        use windows::Win32::Security::SECURITY_ATTRIBUTES;
        let (sid, system) = own_user_sid();
        if system {
            eprintln!("skipped: runs as LocalSystem, which may make any pipe instance");
            return;
        }
        // The user's ACE of the service's pipe alone (svc_proto.rs `pipe_sddl`): no Administrators' ACE, so an elevated
        // test is held to it as well.
        let mut sd = PSECURITY_DESCRIPTOR::default();
        let sddl = format!("O:{sid}D:P(A;;0x{PIPE_USER_ACCESS:08x};;;{sid})");
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(&HSTRING::from(sddl), SDDL_REVISION_1, &mut sd, None).unwrap();
        }
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: false.into(),
        };
        let name = format!(r"\\.\pipe\stillfail-screen-test-access-{}", std::process::id());
        let wide = HSTRING::from(&name);
        let create = || unsafe {
            CreateNamedPipeW(
                &wide,
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                4,
                64 * 1024,
                64 * 1024,
                0,
                Some(&sa),
            )
        };
        // The first instance makes the pipe, under this security; the creator is not checked against it.
        let first = create();
        assert!(!first.is_invalid() && first != INVALID_HANDLE_VALUE);
        let _first = PipeHandle::from_raw(first);
        // A client's access is within the user's.
        let _client = open(&name).unwrap();
        // Another instance needs FILE_CREATE_PIPE_INSTANCE, which the user has not.
        let second = create();
        let err = unsafe { GetLastError() };
        unsafe {
            let _ = LocalFree(Some(HLOCAL(sd.0)));
        }
        if !second.is_invalid() && second != INVALID_HANDLE_VALUE {
            drop(PipeHandle::from_raw(second));
            panic!("the user added an instance of the pipe");
        }
        assert_eq!(err, ERROR_ACCESS_DENIED);
    }

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

        let client = open(&name).unwrap();
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
