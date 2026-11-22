// Service installation, uninstallation, registry configuration, and status probe for stillfail-screen-svc.
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use windows::Win32::Foundation::{CloseHandle, ERROR_SERVICE_DOES_NOT_EXIST, ERROR_SERVICE_EXISTS, HANDLE, HLOCAL, LocalFree};
use windows::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1, SE_FILE_OBJECT,
    SetNamedSecurityInfoW,
};
use windows::Win32::Security::{
    ACL, DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl, GetTokenInformation, PROTECTED_DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows::Win32::System::Registry::{
    HKEY, HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE, REG_DWORD, REG_OPTION_NON_VOLATILE, REG_SZ, RRF_RT_REG_SZ,
    RegCloseKey, RegCreateKeyExW, RegDeleteTreeW, RegGetValueW, RegOpenKeyExW, RegSetValueExW,
};
use windows::Win32::System::Services::{
    ChangeServiceConfig2W, ChangeServiceConfigW, CloseServiceHandle, ControlService, CreateServiceW, DeleteService,
    OpenSCManagerW, OpenServiceW, QueryServiceConfigW, QueryServiceStatusEx, SC_ACTION, SC_ACTION_RESTART,
    SC_HANDLE, SC_MANAGER_ALL_ACCESS, SC_MANAGER_CONNECT, SC_STATUS_PROCESS_INFO,
    SERVICE_ALL_ACCESS, SERVICE_AUTO_START, SERVICE_CONFIG_DESCRIPTION, SERVICE_CONFIG_FAILURE_ACTIONS,
    SERVICE_CONTROL_STOP, SERVICE_DESCRIPTIONW, SERVICE_ERROR_NORMAL, SERVICE_FAILURE_ACTIONSW,
    SERVICE_QUERY_CONFIG, SERVICE_QUERY_STATUS, SERVICE_RUNNING, SERVICE_STATUS,
    SERVICE_STATUS_PROCESS, SERVICE_STOPPED, SERVICE_WIN32_OWN_PROCESS, StartServiceW, QUERY_SERVICE_CONFIGW,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::core::{BOOL, HSTRING, PCWSTR, PWSTR};

use super::svc_pipe;
use super::svc_proto::{
    self, INSTALL_DIR, INSTALL_EXE, KIND_HELLO, MAX_CONTROL_BYTES, PIPE_NAME, PROTO_VERSION, REG_SUBKEY, REG_USER_SID,
    REG_VERSION, SERVICE_DESCRIPTION, SERVICE_DISPLAY_NAME, SERVICE_NAME,
};

struct ScHandle(SC_HANDLE);

impl Drop for ScHandle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = CloseServiceHandle(self.0);
            }
        }
    }
}

struct RegKey(HKEY);

impl Drop for RegKey {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = RegCloseKey(self.0);
            }
        }
    }
}

/// Returns the current process token user's SID string (e.g. `S-1-5-21-...-1001`).
pub fn current_user_sid() -> Result<String, String> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).map_err(|e| format!("OpenProcessToken: {e}"))?;
        let mut needed = 0u32;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut needed);
        let mut buf = vec![0u8; needed.max(64) as usize];
        let res = GetTokenInformation(token, TokenUser, Some(buf.as_mut_ptr() as *mut _), buf.len() as u32, &mut needed);
        let _ = CloseHandle(token);
        res.map_err(|e| format!("GetTokenInformation: {e}"))?;
        let user = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut wide = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut wide).map_err(|e| format!("ConvertSidToStringSidW: {e}"))?;
        let s = wide.to_string().map_err(|e| format!("SID utf16: {e}"))?;
        let _ = LocalFree(Some(HLOCAL(wide.0 as *mut _)));
        Ok(s)
    }
}

/// Reads `AllowedUserSid` persisted in HKLM\SOFTWARE\still.fail\ScreenService.
pub fn read_allowed_user_sid() -> Option<String> {
    unsafe {
        let subkey = HSTRING::from(REG_SUBKEY);
        let value = HSTRING::from(REG_USER_SID);
        let mut key = HKEY::default();
        if RegOpenKeyExW(HKEY_LOCAL_MACHINE, &subkey, Some(0), KEY_READ, &mut key).is_err() {
            return None;
        }
        let _guard = RegKey(key);
        let mut bytes = 0u32;
        if RegGetValueW(key, None, &value, RRF_RT_REG_SZ, None, None, Some(&mut bytes)).is_err() || bytes < 2 {
            return None;
        }
        let mut buf = vec![0u16; (bytes as usize + 1) / 2];
        if RegGetValueW(key, None, &value, RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut bytes)).is_err() {
            return None;
        }
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        let s = String::from_utf16_lossy(&buf[..end]).trim().to_string();
        svc_proto::is_valid_sid(&s).then_some(s)
    }
}

fn write_registry_config(user_sid: &str) -> Result<(), String> {
    unsafe {
        let subkey = HSTRING::from(REG_SUBKEY);
        let mut key = HKEY::default();
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            &subkey,
            Some(0),
            None,
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut key,
            None,
        )
        .ok()
        .map_err(|e| format!("RegCreateKeyExW: {e}"))?;
        let _guard = RegKey(key);

        let sid_wide: Vec<u16> = user_sid.encode_utf16().chain(std::iter::once(0)).collect();
        let sid_bytes = std::slice::from_raw_parts(sid_wide.as_ptr() as *const u8, sid_wide.len() * 2);
        RegSetValueExW(key, &HSTRING::from(REG_USER_SID), Some(0), REG_SZ, Some(sid_bytes))
            .ok()
            .map_err(|e| format!("RegSetValueExW(AllowedUserSid): {e}"))?;

        let ver = PROTO_VERSION.to_le_bytes();
        RegSetValueExW(key, &HSTRING::from(REG_VERSION), Some(0), REG_DWORD, Some(&ver))
            .ok()
            .map_err(|e| format!("RegSetValueExW(Version): {e}"))?;
        Ok(())
    }
}

fn lock_down_directory(dir: &Path) -> Result<(), String> {
    unsafe {
        let mut sd = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            &HSTRING::from(svc_proto::dir_sddl()),
            SDDL_REVISION_1,
            &mut sd,
            None,
        )
        .map_err(|e| format!("ConvertStringSecurityDescriptorToSecurityDescriptorW: {e}"))?;
        let mut present = BOOL(0);
        let mut defaulted = BOOL(0);
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let ok = GetSecurityDescriptorDacl(sd, &mut present, &mut dacl, &mut defaulted);
        let res = if ok.is_ok() && present.as_bool() {
            let wide: Vec<u16> = dir.as_os_str().to_string_lossy().encode_utf16().chain(std::iter::once(0)).collect();
            let err = SetNamedSecurityInfoW(
                PCWSTR(wide.as_ptr()),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                None,
                None,
                Some(dacl),
                None,
            );
            if err.is_ok() { Ok(()) } else { Err(format!("SetNamedSecurityInfoW: {err:?}")) }
        } else {
            Err("GetSecurityDescriptorDacl failed".to_string())
        };
        let _ = LocalFree(Some(HLOCAL(sd.0)));
        res
    }
}

fn query_state(svc: SC_HANDLE) -> Option<u32> {
    unsafe {
        let mut status = SERVICE_STATUS_PROCESS::default();
        let mut needed = 0u32;
        let bytes = std::slice::from_raw_parts_mut(&mut status as *mut _ as *mut u8, std::mem::size_of::<SERVICE_STATUS_PROCESS>());
        QueryServiceStatusEx(svc, SC_STATUS_PROCESS_INFO, Some(bytes), &mut needed).ok()?;
        Some(status.dwCurrentState.0)
    }
}

fn stop_and_wait(svc: SC_HANDLE, timeout: Duration) {
    unsafe {
        let mut st = SERVICE_STATUS::default();
        let _ = ControlService(svc, SERVICE_CONTROL_STOP, &mut st);
    }
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if query_state(svc) == Some(SERVICE_STOPPED.0) {
            return;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
}

fn wait_running(svc: SC_HANDLE, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if query_state(svc) == Some(SERVICE_RUNNING.0) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    query_state(svc) == Some(SERVICE_RUNNING.0)
}

fn configure_service_metadata(svc: SC_HANDLE) {
    unsafe {
        let mut desc_w: Vec<u16> = SERVICE_DESCRIPTION.encode_utf16().chain(std::iter::once(0)).collect();
        let desc = SERVICE_DESCRIPTIONW { lpDescription: PWSTR(desc_w.as_mut_ptr()) };
        let _ = ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, Some(&desc as *const _ as *const _));

        let mut actions = [
            SC_ACTION { Type: SC_ACTION_RESTART, Delay: 2_000 },
            SC_ACTION { Type: SC_ACTION_RESTART, Delay: 5_000 },
            SC_ACTION { Type: SC_ACTION_RESTART, Delay: 10_000 },
        ];
        let fail = SERVICE_FAILURE_ACTIONSW {
            dwResetPeriod: 60,
            lpRebootMsg: PWSTR::null(),
            lpCommand: PWSTR::null(),
            cActions: actions.len() as u32,
            lpsaActions: actions.as_mut_ptr(),
        };
        let _ = ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, Some(&fail as *const _ as *const _));
    }
}

/// Installs (or updates) StillfailScreenService under an admin-only writable directory and starts it.
pub fn install(user_sid_arg: Option<&str>, dir_arg: Option<&str>) -> Value {
    let user_sid = match user_sid_arg {
        Some(s) if svc_proto::is_valid_sid(s) => s.to_string(),
        Some(bad) => return json!({ "ok": false, "error": format!("invalid user SID: {bad}") }),
        None => match current_user_sid() {
            Ok(s) => s,
            Err(e) => return json!({ "ok": false, "error": e }),
        },
    };
    let install_dir = PathBuf::from(dir_arg.unwrap_or(INSTALL_DIR));
    let dest_exe = install_dir.join(INSTALL_EXE);
    let src_exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => return json!({ "ok": false, "error": format!("current_exe: {e}") }),
    };

    let scm = match unsafe { OpenSCManagerW(None, None, SC_MANAGER_ALL_ACCESS) } {
        Ok(h) => ScHandle(h),
        Err(e) => return json!({ "ok": false, "error": format!("OpenSCManagerW (run as Administrator): {e}") }),
    };

    // Stop existing service before replacing its executable.
    let existing = unsafe { OpenServiceW(scm.0, &HSTRING::from(SERVICE_NAME), SERVICE_ALL_ACCESS) }.ok().map(ScHandle);
    if let Some(ref svc) = existing {
        stop_and_wait(svc.0, Duration::from_secs(10));
        std::thread::sleep(Duration::from_millis(250));
    }

    if let Err(e) = std::fs::create_dir_all(&install_dir) {
        return json!({ "ok": false, "error": format!("create_dir_all({}): {e}", install_dir.display()) });
    }
    if let Err(e) = lock_down_directory(&install_dir) {
        return json!({ "ok": false, "error": e });
    }

    // Copy binary into admin-only directory (skip if already running from exact same path).
    let same = src_exe.canonicalize().ok() == dest_exe.canonicalize().ok();
    if !same {
        let mut last_err = None;
        for _ in 0..10 {
            match std::fs::copy(&src_exe, &dest_exe) {
                Ok(_) => {
                    last_err = None;
                    break;
                }
                Err(e) => {
                    last_err = Some(e);
                    std::thread::sleep(Duration::from_millis(250));
                }
            }
        }
        if let Some(e) = last_err {
            return json!({ "ok": false, "error": format!("copy to {}: {e}", dest_exe.display()) });
        }
    }

    if let Err(e) = write_registry_config(&user_sid) {
        return json!({ "ok": false, "error": e });
    }

    let bin_path = format!("\"{}\" --service", dest_exe.display());
    let bin_w = HSTRING::from(&bin_path);
    let disp_w = HSTRING::from(SERVICE_DISPLAY_NAME);

    let svc = if let Some(svc) = existing {
        let res = unsafe {
            ChangeServiceConfigW(
                svc.0,
                SERVICE_WIN32_OWN_PROCESS,
                SERVICE_AUTO_START,
                SERVICE_ERROR_NORMAL,
                &bin_w,
                None,
                None,
                None,
                None,
                None,
                &disp_w,
            )
        };
        if let Err(e) = res {
            return json!({ "ok": false, "error": format!("ChangeServiceConfigW: {e}") });
        }
        svc
    } else {
        let created = unsafe {
            CreateServiceW(
                scm.0,
                &HSTRING::from(SERVICE_NAME),
                &disp_w,
                SERVICE_ALL_ACCESS,
                SERVICE_WIN32_OWN_PROCESS,
                SERVICE_AUTO_START,
                SERVICE_ERROR_NORMAL,
                &bin_w,
                None,
                None,
                None,
                None, // LocalSystem
                None,
            )
        };
        match created {
            Ok(h) => ScHandle(h),
            Err(e) if (e.code().0 as u32 & 0xFFFF) == ERROR_SERVICE_EXISTS.0 => {
                match unsafe { OpenServiceW(scm.0, &HSTRING::from(SERVICE_NAME), SERVICE_ALL_ACCESS) } {
                    Ok(h) => ScHandle(h),
                    Err(e2) => return json!({ "ok": false, "error": format!("OpenServiceW: {e2}") }),
                }
            }
            Err(e) => return json!({ "ok": false, "error": format!("CreateServiceW: {e}") }),
        }
    };

    configure_service_metadata(svc.0);

    if let Err(e) = unsafe { StartServiceW(svc.0, None) } {
        return json!({ "ok": false, "error": format!("StartServiceW: {e}") });
    }
    let running = wait_running(svc.0, Duration::from_secs(10));
    json!({
        "ok": running,
        "service": SERVICE_NAME,
        "installed": true,
        "running": running,
        "path": dest_exe.display().to_string(),
        "userSid": user_sid,
    })
}

/// Stops and removes StillfailScreenService, its registry config, and its installed binary.
pub fn uninstall(dir_arg: Option<&str>) -> Value {
    let install_dir = PathBuf::from(dir_arg.unwrap_or(INSTALL_DIR));
    let dest_exe = install_dir.join(INSTALL_EXE);

    let scm = match unsafe { OpenSCManagerW(None, None, SC_MANAGER_ALL_ACCESS) } {
        Ok(h) => ScHandle(h),
        Err(e) => return json!({ "ok": false, "error": format!("OpenSCManagerW (run as Administrator): {e}") }),
    };

    match unsafe { OpenServiceW(scm.0, &HSTRING::from(SERVICE_NAME), SERVICE_ALL_ACCESS) } {
        Ok(h) => {
            let svc = ScHandle(h);
            stop_and_wait(svc.0, Duration::from_secs(10));
            if let Err(e) = unsafe { DeleteService(svc.0) } {
                return json!({ "ok": false, "error": format!("DeleteService: {e}") });
            }
        }
        Err(e) if (e.code().0 as u32 & 0xFFFF) == ERROR_SERVICE_DOES_NOT_EXIST.0 => {}
        Err(e) => return json!({ "ok": false, "error": format!("OpenServiceW: {e}") }),
    }

    unsafe {
        let _ = RegDeleteTreeW(HKEY_LOCAL_MACHINE, &HSTRING::from(REG_SUBKEY));
    }

    for _ in 0..8 {
        if !dest_exe.exists() || std::fs::remove_file(&dest_exe).is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    let _ = std::fs::remove_dir(&install_dir);

    json!({ "ok": true, "service": SERVICE_NAME, "removed": true })
}

/// Queries service registration/state and probes the active Session-N worker pipe (works non-elevated).
pub fn status() -> Value {
    let mut installed = false;
    let mut running = false;
    let mut bin_path: Option<String> = None;

    if let Ok(scm) = unsafe { OpenSCManagerW(None, None, SC_MANAGER_CONNECT) } {
        let _scm = ScHandle(scm);
        if let Ok(svc) = unsafe { OpenServiceW(scm, &HSTRING::from(SERVICE_NAME), SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG) } {
            let _svc = ScHandle(svc);
            installed = true;
            running = query_state(svc) == Some(SERVICE_RUNNING.0);
            unsafe {
                let mut needed = 0u32;
                let _ = QueryServiceConfigW(svc, None, 0, &mut needed);
                if needed > 0 {
                    let mut buf = vec![0u8; needed as usize];
                    if QueryServiceConfigW(svc, Some(buf.as_mut_ptr() as *mut QUERY_SERVICE_CONFIGW), needed, &mut needed).is_ok() {
                        let cfg = &*(buf.as_ptr() as *const QUERY_SERVICE_CONFIGW);
                        if !cfg.lpBinaryPathName.is_null() {
                            if let Ok(p) = cfg.lpBinaryPathName.to_string() {
                                bin_path = Some(p);
                            }
                        }
                    }
                }
            }
        }
    }

    let mut connected = false;
    let mut version: Option<u64> = None;
    let mut desktop: Option<String> = None;
    let mut secure: Option<bool> = None;
    let mut session: Option<u64> = None;
    let mut pipe_error: Option<String> = None;

    match svc_pipe::connect(PIPE_NAME) {
        Ok(handle) => {
            if let Ok((mut reader, mut writer)) = svc_pipe::split(handle.clone()) {
                let hello = json!({ "version": PROTO_VERSION, "input": false, "capture": false });
                if svc_proto::write_json(&mut writer, KIND_HELLO, &hello).is_ok() {
                    if let Ok(Some((KIND_HELLO, payload))) = svc_proto::read_msg(&mut reader, MAX_CONTROL_BYTES) {
                        if let Ok(ack) = serde_json::from_slice::<Value>(&payload) {
                            connected = ack["ok"].as_bool() == Some(true);
                            version = ack["version"].as_u64();
                            desktop = ack["desktop"].as_str().map(str::to_string);
                            secure = ack["secure"].as_bool();
                            session = ack["session"].as_u64();
                        }
                    }
                }
            }
            handle.cancel();
        }
        Err(e) => {
            if running {
                pipe_error = Some(e.to_string());
            }
        }
    }

    let mut out = json!({
        "service": SERVICE_NAME,
        "installed": installed,
        "running": running,
        "connected": connected,
        "allowedUserSid": read_allowed_user_sid(),
    });
    if let Some(p) = bin_path {
        out["binaryPath"] = json!(p);
    }
    if let Some(v) = version {
        out["version"] = json!(v);
    }
    if let Some(d) = desktop {
        out["desktop"] = json!(d);
    }
    if let Some(s) = secure {
        out["secure"] = json!(s);
    }
    if let Some(sess) = session {
        out["session"] = json!(sess);
    }
    if let Some(err) = pipe_error {
        out["pipeError"] = json!(err);
    }
    out
}
