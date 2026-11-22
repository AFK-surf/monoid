//! The MoonBit front (station/mb's program, `--builder mesh`): the station's iroh endpoint kept for its Node across
//! handovers, so an update binds no new endpoint and its relays stay linked (station/src/mesh/front.ts). The launcher
//! starts it before the first Node (or, taking up one from before it, before the Node of that handover) and keeps it as long as it runs: across Node's handovers and restarts, and across its
//! own `renew` (its pid and the pipe to its stdin handed on). Its stdin is that pipe: the launcher gone, it ends; the
//! launcher stopping kills one that does not (`end`), and one left from before (no launcher's, beside the one kept) is
//! found by its pid file and its arguments and killed (`clean_orphans`). Each Node
//! is told where it listens (STILLFAIL_MESH_FRONT); where none could be started, a Node binds the endpoint itself as
//! before (the mesh addon). Unix only: the front listens on a Unix socket.

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::log;

/// Where the release has the program (beside the station's main.js, as station/src/read/mb-reader.ts finds it).
const PROGRAM_IN_APP: &str = "station/stillfail-reader";
/// The program to run instead of the release's (development, tests: as mb-reader.ts reads it).
const PROGRAM_VAR: &str = "STILLFAIL_MB_READER";
/// How long it may take to listen.
const LISTENS_WITHIN: Duration = Duration::from_secs(10);
/// How it hands Node the streams a connection's other end opens (its first line's `streams`; none said: 1). 2: each
/// with its index, so Node takes them in the order they were opened (a device's credential stream first, 2026-11-13).
/// 3: a route Node gave it (`route`) goes to the program that answers it, Node told the index went (station/mesh/served.ts);
/// 4: a route's segment `*` is any one; 5: meshConfigure, meshRemove, meshAttachLeaf and meshDetachLeaf (a front of 4
/// answered Node's mesh directory "no operation meshConfigure" on every try, 2026-11-18); 6: iroh.probeRelay (#7567),
/// unix backlog/retry and conn.hand skip (#7568), and noq path-idle/RTT-stall fixes (#7869/#7899/#7919), which a front
/// kept across updates otherwise never takes up (one of 5 ran a 40-hour-old binary, 2026-11-21); 7: noq-proto BBRv3
/// idle app_limited (#852) / startup pacing (#802) fixes and 4 MiB stream_receive_window (#8093).
/// A front kept from before a raise here is replaced once by the launcher that takes it up (`current`): the one thing
/// that does not come with an update, as it is kept across them.
pub const STREAMS: u64 = 7;

pub struct Front {
    pub pid: i32,
    /// The write end of its stdin (never written: closed, it ends).
    input: OwnedFd,
    /// Where it listens.
    pub socket: PathBuf,
    /// Where its pid is written (`<data>/run/front.pid`), so a launcher that never had it as its child finds it.
    pid_file: PathBuf,
    /// When it started; none for one a launcher before this one started.
    started: Option<Instant>,
    /// How it hands Node streams (`STREAMS`).
    streams: u64,
    /// The launcher's executable identity when this front was started. macOS records it on the front's sockets.
    #[cfg(target_os = "macos")]
    launcher_uuid: Option<String>,
    /// A front from before this identity was recorded must be replaced once.
    #[cfg(target_os = "macos")]
    uuid_recorded: bool,
}

impl Front {
    fn program(app: &Path) -> Option<PathBuf> {
        if let Some(given) = std::env::var_os(PROGRAM_VAR).filter(|v| !v.is_empty()) {
            return Some(PathBuf::from(given));
        }
        let program = app.join(PROGRAM_IN_APP);
        program.is_file().then_some(program)
    }

    /// Whether the release at `app` has the program (where it does, one that does not start is tried again later).
    pub fn in_release(app: &Path) -> bool {
        Front::program(app).is_some()
    }

    /// The front for the station of `data`, listening; none where the release has none or it did not start (said).
    pub fn start(app: &Path, data: &Path) -> Option<Front> {
        // None of this launcher's runs (it starts one only where it has none): any other of this data directory is left
        // from before (a launcher killed, one from before front.pid) and holds the station's key on the relays.
        clean_orphans(data, None);
        let program = Front::program(app)?;
        let run = data.join("run");
        let socket = run.join("front.sock");
        let pid_file = run.join(PID_FILE);
        let mut command = Command::new(&program);
        command
            .args(["--builder", "mesh", "--socket"])
            .arg(&socket)
            .arg("--shell-dir")
            .arg(run.join("front"))
            // Its shell's threads carry every byte of the station's iroh: as many as the machine has cores, as the addon's
            // (tokio's own count) had (two, an app's, held bulk transfers 15% under the addon's).
            .env("STILLFAIL_SHELL_THREADS", std::thread::available_parallelism().map_or(2, |n| n.get()).to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .process_group(0);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                log::warn(&format!("the front ({}) did not start: {error}; each Node binds the station's endpoint itself", program.display()));
                return None;
            }
        };
        let pid = child.id() as i32;
        write_pid(&pid_file, pid);
        // SAFETY: the pipe's write end, taken from the child's handle, owned here from now on.
        let input = unsafe { OwnedFd::from_raw_fd(child.stdin.take().unwrap().into_raw_fd()) };
        let mut out = child.stdout.take().unwrap();
        // Reaped by waitpid in run.rs's serve(), not by std.
        drop(child);
        match listening(&mut out) {
            Some((said, streams)) if said == socket.to_string_lossy() => {
                log::info(&format!("the front listens (pid {pid}): {}", socket.display()));
                Some(Front {
                    pid, input, socket, pid_file, started: Some(Instant::now()), streams,
                    #[cfg(target_os = "macos")]
                    launcher_uuid: executable_uuid(),
                    #[cfg(target_os = "macos")]
                    uuid_recorded: true,
                })
            }
            other => {
                log::warn(&format!("the front (pid {pid}) did not listen ({other:?}); each Node binds the station's endpoint itself"));
                // SAFETY: a signal to a child of this process, then its exit waited for (it would be left a zombie, or,
                // where the kill did not take, a second endpoint on the station's key).
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                    libc::waitpid(pid, std::ptr::null_mut(), 0);
                }
                forget_pid(&pid_file, pid);
                None
            }
        }
    }

    /// It ended: another in its place, unless it ended sooner than `lives` after it started (said; the lifecycle tries
    /// again later: `front_gone`).
    pub fn ended(self, app: &Path, data: &Path, how: &str, lives: Duration) -> Option<Front> {
        if let Some(started) = self.started.filter(|s| s.elapsed() < lives) {
            forget_pid(&self.pid_file, self.pid);
            log::error(&format!("the front (pid {}) {how} {} ms after it started; not started again for now, Nodes bind the station's endpoint themselves meanwhile (the one serving hands over to one)", self.pid, started.elapsed().as_millis()));
            return None;
        }
        log::warn(&format!("the front (pid {}) {how}; starting another", self.pid));
        forget_pid(&self.pid_file, self.pid);
        drop(self);
        Front::start(app, data)
    }

    /// What the launcher it becomes (`renew`) takes it up by.
    pub fn state(&self) -> Value {
        let state = json!({ "pid": self.pid, "input": self.input.as_raw_fd(), "socket": self.socket, "streams": self.streams });
        #[cfg(target_os = "macos")]
        let state = {
            let mut state = state;
            state["launcherUuid"] = json!(self.launcher_uuid);
            state
        };
        state
    }

    pub fn fds(&self) -> Vec<RawFd> {
        vec![self.input.as_raw_fd()]
    }

    /// One a launcher before this one handed on.
    pub fn resumed(state: &Value) -> Option<Front> {
        let pid = state["pid"].as_i64().and_then(|n| i32::try_from(n).ok())?;
        let input = state["input"].as_i64().and_then(|n| RawFd::try_from(n).ok()).filter(|n| *n > 2)?;
        let socket = PathBuf::from(state["socket"].as_str()?);
        let pid_file = socket.with_file_name(PID_FILE);
        crate::run::cloexec_on(input);
        // (a launcher from before front.pid wrote none)
        write_pid(&pid_file, pid);
        // SAFETY: the descriptor the launcher before handed on, owned by this one from here.
        Some(Front {
            pid, input: unsafe { OwnedFd::from_raw_fd(input) }, socket, pid_file, started: None,
            streams: state["streams"].as_u64().unwrap_or(1),
            #[cfg(target_os = "macos")]
            launcher_uuid: state["launcherUuid"].as_str().map(str::to_string),
            #[cfg(target_os = "macos")]
            uuid_recorded: state.get("launcherUuid").is_some(),
        })
    }

    /// Itself where it hands streams as this launcher's release does; else ended (its connections go with it, the
    /// devices dial again), so that one of the release starts in its place.
    pub fn current(self) -> Option<Front> {
        #[cfg(target_os = "macos")]
        let identity_changed = identity_needs_refresh(self.uuid_recorded, self.launcher_uuid.as_deref(), executable_uuid().as_deref());
        #[cfg(not(target_os = "macos"))]
        let identity_changed = false;
        if self.streams >= STREAMS && !identity_changed {
            return Some(self);
        }
        if identity_changed {
            log::warn(&format!("the front (pid {}) was started by another launcher identity: ending it so macOS can match its local network permission", self.pid));
        } else {
            log::warn(&format!("the front (pid {}) hands streams as {} and this release as {STREAMS}: ending it for the release's", self.pid, self.streams));
        }
        // SAFETY: a signal to this process's child (a launcher before this one started it in this same process), then
        // its exit waited for, so the next binds its socket and the station's endpoint with it gone.
        unsafe {
            libc::kill(self.pid, libc::SIGKILL);
            libc::waitpid(self.pid, std::ptr::null_mut(), 0);
        }
        forget_pid(&self.pid_file, self.pid);
        None
    }

    /// Ended as the launcher stops: its stdin closed (it ends by itself, its connections closed as it means), then,
    /// where it has not ended within ENDS_WITHIN (a program whose thread that reads stdin is held: its runtime's threads
    /// would keep the endpoint up on the relays with no launcher), killed; waited for either way.
    pub fn end(self) {
        let Front { pid, input, pid_file, .. } = self;
        drop(input);
        let deadline = Instant::now() + ENDS_WITHIN;
        loop {
            // SAFETY: waitpid on this process's child, without blocking.
            let done = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
            if done != 0 {
                break;
            }
            if Instant::now() >= deadline {
                log::warn(&format!("the front (pid {pid}) did not end with its stdin; killed"));
                // SAFETY: a signal to this process's child, then its exit waited for.
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                    libc::waitpid(pid, std::ptr::null_mut(), 0);
                }
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        forget_pid(&pid_file, pid);
    }
}

/// Where a data directory's run/ has its front's pid.
const PID_FILE: &str = "front.pid";
/// How long a front is given to end by itself as the launcher stops.
const ENDS_WITHIN: Duration = Duration::from_secs(1);
/// How long a front left from before is waited for to be gone once killed.
const ORPHAN_GONE_WITHIN: Duration = Duration::from_secs(2);

/// Written whole (a file of its own beside it, renamed into place).
fn write_pid(path: &Path, pid: i32) {
    let own = path.with_extension(format!("pid.{}", std::process::id()));
    if let Err(error) = std::fs::write(&own, format!("{pid}\n")).and_then(|_| std::fs::rename(&own, path)) {
        log::warn(&format!("{}: {error}", path.display()));
        let _ = std::fs::remove_file(&own);
    }
}

fn read_pid(path: &Path) -> Option<i32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok().filter(|pid| *pid > 0)
}

/// Removed where it still names `pid` (another written since is that one's).
fn forget_pid(path: &Path, pid: i32) {
    if read_pid(path) == Some(pid) {
        let _ = std::fs::remove_file(path);
    }
}

/// Every front of `data`'s station but `keep` (the one this launcher has) killed, and waited for to be gone, so that
/// one endpoint alone holds the station's key on the relays: two take each other's place there, and every device's
/// connection fails (2026-11-16: a front from before front.pid, left by a launcher killed, beside the one started after
/// it). Found by front.pid and by every process of this user whose arguments are a front's of this data directory's
/// socket (`--builder mesh --socket <data>/run/front.sock`): the system's own calls, no program run, nothing asked of
/// the person.
pub fn clean_orphans(data: &Path, keep: Option<i32>) {
    let run = data.join("run");
    let socket = run.join("front.sock");
    let pid_file = run.join(PID_FILE);
    let me = std::process::id() as i32;
    let other = |pid: i32| pid > 0 && pid != me && Some(pid) != keep;
    let mut found: Vec<i32> = vec![];
    let said = read_pid(&pid_file);
    for pid in said.into_iter().chain(own_processes()) {
        if other(pid) && !found.contains(&pid) && args_of(pid).is_some_and(|args| fronts_of(&args, &socket)) {
            found.push(pid);
        }
    }
    if let Some(pid) = said.filter(|pid| other(*pid) && !found.contains(pid)) {
        // A pid no front of this station's has now (it ended, or the system gave it to another program).
        forget_pid(&pid_file, pid);
    }
    if found.is_empty() {
        return;
    }
    for pid in &found {
        log::warn(&format!("a front of this station left from before (pid {pid}) holds its endpoint beside {}: killed", keep.map_or("none".to_string(), |k| format!("the front (pid {k})"))));
        // SAFETY: a signal to a process of this user that runs as this data directory's front.
        unsafe { libc::kill(*pid, libc::SIGKILL) };
    }
    let deadline = Instant::now() + ORPHAN_GONE_WITHIN;
    loop {
        found.retain(|pid| {
            // SAFETY: waitpid without blocking (only this process's children are reaped: a front a launcher before this
            // one started in this process), then signal 0, which only asks whether it is there.
            unsafe {
                libc::waitpid(*pid, std::ptr::null_mut(), libc::WNOHANG);
                libc::kill(*pid, 0) == 0
            }
        });
        if found.is_empty() || Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    for pid in &found {
        log::warn(&format!("the front left from before (pid {pid}) is still there {} ms after it was killed", ORPHAN_GONE_WITHIN.as_millis()));
    }
    if let Some(pid) = said.filter(|pid| !found.contains(pid) && Some(*pid) != keep) {
        forget_pid(&pid_file, pid);
    }
}

/// Whether `args` are a front's (`--builder mesh`) listening at `socket`: the same path, or one in the same directory
/// as the system resolves it (macOS's /var is /private/var).
fn fronts_of(args: &[std::ffi::OsString], socket: &Path) -> bool {
    let mesh = args.windows(2).any(|w| w[0] == "--builder" && w[1] == "mesh");
    let at = args.windows(2).find(|w| w[0] == "--socket").map(|w| PathBuf::from(&w[1]));
    mesh && at.is_some_and(|at| same_socket(&at, socket))
}

fn same_socket(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    let dir = |p: &Path| p.parent().and_then(|d| std::fs::canonicalize(d).ok());
    a.file_name() == b.file_name() && a.file_name().is_some() && dir(a).is_some() && dir(a) == dir(b)
}

/// The processes of this user, as the system lists them.
#[cfg(target_os = "macos")]
fn own_processes() -> Vec<i32> {
    unsafe extern "C" {
        fn proc_listpids(kind: u32, typeinfo: u32, buffer: *mut libc::c_void, buffersize: libc::c_int) -> libc::c_int;
    }
    const PROC_UID_ONLY: u32 = 4;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    // SAFETY: a null buffer asks for the size needed.
    let size = unsafe { proc_listpids(PROC_UID_ONLY, uid, std::ptr::null_mut(), 0) };
    if size <= 0 {
        return vec![];
    }
    // Room for some started meanwhile.
    let mut pids = vec![0i32; size as usize / std::mem::size_of::<i32>() + 64];
    // SAFETY: a live buffer of the size given.
    let got = unsafe { proc_listpids(PROC_UID_ONLY, uid, pids.as_mut_ptr().cast(), (pids.len() * std::mem::size_of::<i32>()) as libc::c_int) };
    if got <= 0 {
        return vec![];
    }
    pids.truncate(got as usize / std::mem::size_of::<i32>());
    pids.retain(|pid| *pid > 0);
    pids
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn own_processes() -> Vec<i32> {
    let Ok(dir) = std::fs::read_dir("/proc") else { return vec![] };
    dir.filter_map(|e| e.ok()?.file_name().to_str()?.parse::<i32>().ok()).collect()
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
fn own_processes() -> Vec<i32> {
    vec![]
}

/// A process's arguments, where it is this user's (KERN_PROCARGS2: argc, the executable's path, then the arguments).
#[cfg(target_os = "macos")]
fn args_of(pid: i32) -> Option<Vec<std::ffi::OsString>> {
    use std::os::unix::ffi::OsStrExt;
    const CTL_KERN: libc::c_int = 1;
    const KERN_ARGMAX: libc::c_int = 8;
    const KERN_PROCARGS2: libc::c_int = 49;
    let mut most: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let mut name = [CTL_KERN, KERN_ARGMAX];
    // SAFETY: sysctl reading one int into a live one of its size.
    if unsafe { libc::sysctl(name.as_mut_ptr(), 2, (&mut most as *mut libc::c_int).cast(), &mut size, std::ptr::null_mut(), 0) } != 0 || most <= 0 {
        return None;
    }
    let mut buf = vec![0u8; most as usize];
    let mut size = buf.len();
    let mut name = [CTL_KERN, KERN_PROCARGS2, pid];
    // SAFETY: sysctl into a live buffer of the size given; it fails for another user's process.
    if unsafe { libc::sysctl(name.as_mut_ptr(), 3, buf.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) } != 0 {
        return None;
    }
    let buf = buf.get(..size)?;
    let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?);
    let mut rest = &buf[4..];
    // The executable's path, then the NULs that pad it.
    let path_end = rest.iter().position(|b| *b == 0)?;
    rest = &rest[path_end..];
    let start = rest.iter().position(|b| *b != 0)?;
    rest = &rest[start..];
    Some(rest.split(|b| *b == 0).take(argc.max(0) as usize).map(|a| std::ffi::OsStr::from_bytes(a).to_os_string()).collect())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn args_of(pid: i32) -> Option<Vec<std::ffi::OsString>> {
    use std::os::unix::ffi::OsStrExt;
    // Its real uid this user's (Uid: real, effective, saved, filesystem).
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let uid: u32 = status.lines().find(|l| l.starts_with("Uid:"))?.split_whitespace().nth(1)?.parse().ok()?;
    // SAFETY: getuid has no preconditions.
    if uid != unsafe { libc::getuid() } {
        return None;
    }
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(cmdline.split(|b| *b == 0).filter(|a| !a.is_empty()).map(|a| std::ffi::OsStr::from_bytes(a).to_os_string()).collect())
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
fn args_of(_pid: i32) -> Option<Vec<std::ffi::OsString>> {
    None
}

#[cfg(test)]
mod orphan_tests {
    use super::{args_of, fronts_of};
    use std::ffi::OsString;
    use std::path::Path;

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn a_front_is_known_by_its_builder_and_socket() {
        let socket = Path::new("/data/run/front.sock");
        assert!(fronts_of(&args(&["/app/station/stillfail-reader", "--builder", "mesh", "--socket", "/data/run/front.sock", "--shell-dir", "/data/run/front"]), socket));
        assert!(!fronts_of(&args(&["stillfail-reader", "--builder", "mesh", "--socket", "/other/run/front.sock"]), socket));
        assert!(!fronts_of(&args(&["stillfail-reader", "--builder", "footprint", "--socket", "/data/run/front.sock"]), socket));
        assert!(!fronts_of(&args(&["stillfail-reader", "--serve", "/data/run/front.sock"]), socket));
    }

    #[test]
    fn a_socket_through_a_link_to_its_directory_is_the_same() {
        let dir = std::env::temp_dir().join(format!("front-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("real/run")).unwrap();
        std::os::unix::fs::symlink(dir.join("real"), dir.join("link")).unwrap();
        let through = dir.join("link/run/front.sock");
        let list = vec![OsString::from("--builder"), OsString::from("mesh"), OsString::from("--socket"), through.into_os_string()];
        assert!(fronts_of(&list, &dir.join("real/run/front.sock")));
        assert!(!fronts_of(&list, &dir.join("real/run/other.sock")));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn this_process_s_own_arguments_read() {
        let own = args_of(std::process::id() as i32).expect("this process's arguments");
        assert_eq!(own, std::env::args_os().collect::<Vec<_>>());
    }
}

/// A missing field means a front from before identities were carried. If dyld could not read a recorded UUID, keep
/// the front: repeatedly replacing it would interrupt every handover without making its identity any more certain.
#[cfg(any(target_os = "macos", test))]
fn identity_needs_refresh(recorded: bool, before: Option<&str>, now: Option<&str>) -> bool {
    !recorded || matches!((before, now), (Some(a), Some(b)) if a != b)
}

/// UUID of the executable actually running, not the path the updater may already have replaced.
#[cfg(target_os = "macos")]
fn executable_uuid() -> Option<String> {
    unsafe extern "C" {
        fn _dyld_get_image_header(index: u32) -> *const u8;
    }
    // SAFETY: dyld's first image is this live executable; its 64-bit header and declared load commands are mapped.
    let image = unsafe { _dyld_get_image_header(0) };
    if image.is_null() { return None; }
    // All supported macOS station builds are 64-bit. Check the bounded load command size before reading it.
    let header = unsafe { std::slice::from_raw_parts(image, 32) };
    if u32::from_ne_bytes(header[0..4].try_into().ok()?) != 0xfeedfacf { return None; }
    let size = u32::from_ne_bytes(header[20..24].try_into().ok()?) as usize;
    if size > 1024 * 1024 { return None; }
    let commands = unsafe { std::slice::from_raw_parts(image.add(32), size) };
    uuid_in_commands(commands)
}

#[cfg(any(target_os = "macos", test))]
fn uuid_in_commands(mut commands: &[u8]) -> Option<String> {
    while commands.len() >= 8 {
        let kind = u32::from_ne_bytes(commands[0..4].try_into().ok()?);
        let size = u32::from_ne_bytes(commands[4..8].try_into().ok()?) as usize;
        if size < 8 || size > commands.len() { return None; }
        if kind == 0x1b && size >= 24 {
            return Some(commands[8..24].iter().map(|b| format!("{b:02x}")).collect());
        }
        commands = &commands[size..];
    }
    None
}

#[cfg(test)]
mod identity_tests {
    use super::{identity_needs_refresh, uuid_in_commands};

    #[test]
    fn old_front_is_replaced_once_and_same_launcher_keeps_connections() {
        assert!(identity_needs_refresh(false, None, Some("new")));
        assert!(!identity_needs_refresh(true, Some("new"), Some("new")));
        assert!(identity_needs_refresh(true, Some("old"), Some("new")));
        assert!(!identity_needs_refresh(true, None, Some("new")));
        assert!(!identity_needs_refresh(true, Some("old"), None));
    }

    #[test]
    fn reads_uuid_after_another_load_command_and_rejects_bad_lengths() {
        let mut commands = Vec::new();
        commands.extend_from_slice(&1u32.to_ne_bytes());
        commands.extend_from_slice(&8u32.to_ne_bytes());
        commands.extend_from_slice(&0x1bu32.to_ne_bytes());
        commands.extend_from_slice(&24u32.to_ne_bytes());
        commands.extend(0..16);
        assert_eq!(uuid_in_commands(&commands).as_deref(), Some("000102030405060708090a0b0c0d0e0f"));
        assert_eq!(uuid_in_commands(&commands[..commands.len() - 1]), None);
        commands[4..8].copy_from_slice(&0u32.to_ne_bytes());
        assert_eq!(uuid_in_commands(&commands), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn loaded_executable_uuid_matches_the_file() {
        let file = std::env::current_exe().unwrap();
        let output = std::process::Command::new("dwarfdump").arg("--uuid").arg(file).output().unwrap();
        assert!(output.status.success());
        let printed = String::from_utf8(output.stdout).unwrap();
        let uuid = printed.split_whitespace().nth(1).unwrap().replace('-', "").to_lowercase();
        assert_eq!(super::executable_uuid().as_deref(), Some(uuid.as_str()));
    }
}

/// Where it said it listens and how it hands streams (`{"listening": path, "streams": n}`, its first line), within
/// LISTENS_WITHIN.
fn listening(out: &mut std::process::ChildStdout) -> Option<(String, u64)> {
    let deadline = Instant::now() + LISTENS_WITHIN;
    let mut line = vec![];
    let mut byte = [0u8; 1];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return None;
        }
        let mut fd = libc::pollfd { fd: out.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: poll on one live pollfd.
        let polled = unsafe { libc::poll(&mut fd, 1, left.as_millis().min(i32::MAX as u128) as libc::c_int) };
        if polled < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if polled <= 0 {
            return None;
        }
        match out.read(&mut byte) {
            Ok(1) if byte[0] == b'\n' => break,
            Ok(1) => line.push(byte[0]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            _ => return None,
        }
    }
    let said: Value = serde_json::from_slice(&line).ok()?;
    said["listening"].as_str().map(|path| (path.to_string(), said["streams"].as_u64().unwrap_or(1)))
}

/// Whether the front listening at `socket` answers an ask within `within`: a connection as a Node's, one line asked
/// and its answer read, then closed (it parts with the connection as with a Node's that went: front/mesh.mbt `serve`,
/// quietly). A connection alone would not do: the system takes it into the socket's backlog whether or not the program
/// runs. The ask is the endpoint's relays (`relayStatus`), which goes through the shell to its iroh endpoint where one is
/// bound, so a front whose socket's loop runs while its shell or endpoint is held is not taken for one that answers; none
/// bound, it is answered an error of the same id.
pub fn answers(socket: &Path, within: Duration) -> bool {
    use std::io::{BufRead, BufReader, Write};
    let Some(stream) = connect_now(socket) else { return false };
    if stream.set_read_timeout(Some(within)).is_err() || stream.set_write_timeout(Some(within)).is_err() {
        return false;
    }
    if (&stream).write_all(b"{\"id\":1,\"op\":\"relayStatus\"}\n").is_err() {
        return false;
    }
    let mut line = String::new();
    let read = BufReader::new(&stream).read_line(&mut line);
    let _ = stream.shutdown(std::net::Shutdown::Both);
    read.is_ok_and(|n| n > 0) && serde_json::from_str::<Value>(&line).is_ok_and(|said| said["id"] == 1)
}

/// A connection to `socket` made at once, or none: one whose backlog is full (a program that does not take them) is
/// not waited on.
fn connect_now(socket: &Path) -> Option<std::os::unix::net::UnixStream> {
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: a socket made here, owned by the OwnedFd from the start.
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return None;
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    // SAFETY: fcntl on the descriptor just made.
    unsafe {
        libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
        let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
        libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
    // SAFETY: a zeroed sockaddr_un, its path copied in within its length (one byte left for the NUL).
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let path = socket.as_os_str().as_bytes();
    if path.len() >= addr.sun_path.len() {
        return None;
    }
    for (to, from) in addr.sun_path.iter_mut().zip(path) {
        *to = *from as libc::c_char;
    }
    let len = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
    // SAFETY: connect with the address filled above.
    if unsafe { libc::connect(fd.as_raw_fd(), (&addr as *const libc::sockaddr_un).cast(), len) } != 0 {
        return None;
    }
    // SAFETY: as above; blocking again, the reads and writes then bounded by their timeouts.
    unsafe {
        let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
        libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags & !libc::O_NONBLOCK);
    }
    Some(std::os::unix::net::UnixStream::from(fd))
}
