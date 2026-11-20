// stillfail-screen-svc: LocalSystem Windows service + active-session SYSTEM worker for still.fail remote screens.
//
// Subcommands:
//   stillfail-screen-svc install [--user-sid <SID>] [--dir <path>]
//                                  (elevated) installs into C:\Program Files\still.fail\screen-service and starts service
//   stillfail-screen-svc uninstall [--dir <path>]
//                                  (elevated) stops & removes service, registry config, and installed binary
//   stillfail-screen-svc status    (non-elevated ok) prints JSON status of SCM registration + worker pipe probe
//   stillfail-screen-svc --service (called by Windows SCM as LocalSystem in Session 0) supervises the Session-N worker
//   stillfail-screen-svc --worker --session <id> --user-sid <SID>
//                                  (spawned by --service in the active console session as LocalSystem)

#[cfg(windows)]
mod display;
#[allow(dead_code)]
mod hdr;
#[cfg(windows)]
mod input;
#[cfg_attr(not(windows), allow(dead_code))]
mod mouse;
#[allow(dead_code)]
mod scale;
#[cfg(windows)]
mod svc_install;
#[cfg(windows)]
mod svc_pipe;
#[allow(dead_code)]
mod svc_proto;
#[cfg(windows)]
mod svc_worker;

#[cfg(windows)]
mod service_host {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    use windows::Win32::Foundation::{CloseHandle, HANDLE, LUID, WAIT_OBJECT_0};
    use windows::Win32::Security::{
        AdjustTokenPrivileges, DuplicateTokenEx, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW, SE_PRIVILEGE_ENABLED,
        SecurityImpersonation, SetTokenInformation, TOKEN_ADJUST_DEFAULT, TOKEN_ADJUST_PRIVILEGES,
        TOKEN_ADJUST_SESSIONID, TOKEN_ALL_ACCESS, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_PRIVILEGES, TOKEN_QUERY,
        TokenPrimary, TokenSessionId,
    };
    use windows::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId;
    use windows::Win32::System::Services::{
        RegisterServiceCtrlHandlerExW, SERVICE_ACCEPT_SESSIONCHANGE, SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP,
        SERVICE_CONTROL_INTERROGATE, SERVICE_CONTROL_SESSIONCHANGE, SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP,
        SERVICE_RUNNING, SERVICE_START_PENDING, SERVICE_STATUS, SERVICE_STATUS_HANDLE, SERVICE_STOP_PENDING,
        SERVICE_STOPPED, SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS, SetServiceStatus,
        StartServiceCtrlDispatcherW,
    };
    use windows::Win32::System::Threading::{
        CREATE_NO_WINDOW, CreateProcessAsUserW, GetCurrentProcess, NORMAL_PRIORITY_CLASS, OpenProcessToken,
        PROCESS_INFORMATION, STARTUPINFOW, TerminateProcess, WaitForSingleObject,
    };
    use windows::core::{HSTRING, PWSTR};

    use super::svc_install;
    use super::svc_proto::SERVICE_NAME;

    static STOP: AtomicBool = AtomicBool::new(false);
    static mut STATUS_HANDLE: SERVICE_STATUS_HANDLE = SERVICE_STATUS_HANDLE(std::ptr::null_mut());

    fn report(state: windows::Win32::System::Services::SERVICE_STATUS_CURRENT_STATE, controls: u32, wait_hint: u32) {
        unsafe {
            let h = STATUS_HANDLE;
            if h.is_invalid() {
                return;
            }
            let st = SERVICE_STATUS {
                dwServiceType: SERVICE_WIN32_OWN_PROCESS,
                dwCurrentState: state,
                dwControlsAccepted: controls,
                dwWin32ExitCode: 0,
                dwServiceSpecificExitCode: 0,
                dwCheckPoint: 0,
                dwWaitHint: wait_hint,
            };
            let _ = SetServiceStatus(h, &st);
        }
    }

    unsafe extern "system" fn ctrl_handler(control: u32, _event_type: u32, _event_data: *mut core::ffi::c_void, _ctx: *mut core::ffi::c_void) -> u32 {
        match control {
            SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN => {
                STOP.store(true, Ordering::SeqCst);
                report(SERVICE_STOP_PENDING, 0, 5_000);
                0
            }
            SERVICE_CONTROL_SESSIONCHANGE | SERVICE_CONTROL_INTERROGATE => 0,
            _ => 120, // ERROR_CALL_NOT_IMPLEMENTED
        }
    }

    fn enable_privileges(token: HANDLE) {
        for name in ["SeAssignPrimaryTokenPrivilege", "SeIncreaseQuotaPrivilege", "SeTcbPrivilege"] {
            unsafe {
                let mut luid = LUID::default();
                if LookupPrivilegeValueW(None, &HSTRING::from(name), &mut luid).is_ok() {
                    let tp = TOKEN_PRIVILEGES {
                        PrivilegeCount: 1,
                        Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }],
                    };
                    let _ = AdjustTokenPrivileges(token, false, Some(&tp), 0, None, None);
                }
            }
        }
    }

    fn spawn_session_worker(session_id: u32, user_sid: &str) -> Option<HANDLE> {
        let exe = std::env::current_exe().ok()?;
        let cmd = format!("\"{}\" --worker --session {} --user-sid {}", exe.display(), session_id, user_sid);
        let mut cmd_w: Vec<u16> = cmd.encode_utf16().chain(std::iter::once(0)).collect();
        let mut desktop_w: Vec<u16> = "winsta0\\default".encode_utf16().chain(std::iter::once(0)).collect();

        unsafe {
            let mut self_tok = HANDLE::default();
            OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_PRIVILEGES | TOKEN_ADJUST_SESSIONID | TOKEN_ASSIGN_PRIMARY,
                &mut self_tok,
            )
            .ok()?;
            enable_privileges(self_tok);
            let mut primary = HANDLE::default();
            let dup = DuplicateTokenEx(self_tok, TOKEN_ALL_ACCESS, None, SecurityImpersonation, TokenPrimary, &mut primary);
            let _ = CloseHandle(self_tok);
            dup.ok()?;

            if SetTokenInformation(
                primary,
                TokenSessionId,
                &session_id as *const u32 as *const _,
                std::mem::size_of::<u32>() as u32,
            )
            .is_err()
            {
                let _ = CloseHandle(primary);
                return None;
            }

            let si = STARTUPINFOW {
                cb: std::mem::size_of::<STARTUPINFOW>() as u32,
                lpDesktop: PWSTR(desktop_w.as_mut_ptr()),
                ..Default::default()
            };
            let mut pi = PROCESS_INFORMATION::default();
            let ok = CreateProcessAsUserW(
                Some(primary),
                None,
                Some(PWSTR(cmd_w.as_mut_ptr())),
                None,
                None,
                false,
                CREATE_NO_WINDOW | NORMAL_PRIORITY_CLASS,
                None,
                None,
                &si,
                &mut pi,
            );
            let _ = CloseHandle(primary);
            if ok.is_err() {
                return None;
            }
            let _ = CloseHandle(pi.hThread);
            Some(pi.hProcess)
        }
    }

    fn kill_worker(proc: &mut Option<(u32, HANDLE)>) {
        if let Some((_, h)) = proc.take() {
            unsafe {
                let _ = TerminateProcess(h, 0);
                let _ = WaitForSingleObject(h, 3_000);
                let _ = CloseHandle(h);
            }
        }
    }

    unsafe extern "system" fn service_main(_argc: u32, _argv: *mut PWSTR) {
        let name = HSTRING::from(SERVICE_NAME);
        let Ok(handle) = (unsafe { RegisterServiceCtrlHandlerExW(&name, Some(ctrl_handler), None) }) else {
            return;
        };
        unsafe {
            STATUS_HANDLE = handle;
        }
        report(SERVICE_START_PENDING, 0, 5_000);
        let controls = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE;
        report(SERVICE_RUNNING, controls, 0);

        let mut worker: Option<(u32, HANDLE)> = None;
        while !STOP.load(Ordering::SeqCst) {
            let active = unsafe { WTSGetActiveConsoleSessionId() };
            let sid = svc_install::read_allowed_user_sid();

            // Check whether existing worker is still alive and in the active console session.
            if let Some((w_sess, h)) = worker {
                let exited = unsafe { WaitForSingleObject(h, 0) } == WAIT_OBJECT_0;
                if exited || active == 0xFFFF_FFFF || w_sess != active || sid.is_none() {
                    kill_worker(&mut worker);
                }
            }

            if worker.is_none() && active != 0xFFFF_FFFF {
                if let Some(ref user_sid) = sid {
                    if let Some(h) = spawn_session_worker(active, user_sid) {
                        worker = Some((active, h));
                    }
                }
            }

            // Sleep in short slices so stop requests respond immediately.
            for _ in 0..10 {
                if STOP.load(Ordering::SeqCst) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }

        kill_worker(&mut worker);
        report(SERVICE_STOPPED, 0, 0);
    }

    pub fn run_dispatcher() -> Result<(), String> {
        let mut name_w: Vec<u16> = SERVICE_NAME.encode_utf16().chain(std::iter::once(0)).collect();
        let table = [
            SERVICE_TABLE_ENTRYW { lpServiceName: PWSTR(name_w.as_mut_ptr()), lpServiceProc: Some(service_main) },
            SERVICE_TABLE_ENTRYW::default(),
        ];
        unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) }.map_err(|e| format!("StartServiceCtrlDispatcherW: {e}"))
    }
}

#[cfg(windows)]
fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

#[cfg(windows)]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("--service") => {
            if let Err(e) = service_host::run_dispatcher() {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        Some("--worker") => {
            let session = arg_value(&args, "--session").and_then(|s| s.parse::<u32>().ok()).unwrap_or(1);
            let user_sid = arg_value(&args, "--user-sid").or_else(svc_install::read_allowed_user_sid).unwrap_or_default();
            if let Err(e) = svc_worker::run_worker(session, &user_sid) {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        Some("install") => {
            let sid = arg_value(&args, "--user-sid");
            let dir = arg_value(&args, "--dir");
            let out = svc_install::install(sid.as_deref(), dir.as_deref());
            println!("{out}");
            if out["ok"].as_bool() != Some(true) {
                std::process::exit(1);
            }
        }
        Some("uninstall") => {
            let dir = arg_value(&args, "--dir");
            let out = svc_install::uninstall(dir.as_deref());
            println!("{out}");
            if out["ok"].as_bool() != Some(true) {
                std::process::exit(1);
            }
        }
        Some("status") => {
            println!("{}", svc_install::status());
        }
        _ => {
            eprintln!("usage: stillfail-screen-svc install [--user-sid SID] [--dir PATH] | uninstall [--dir PATH] | status");
            std::process::exit(2);
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("stillfail-screen-svc is for Windows");
    std::process::exit(2);
}
