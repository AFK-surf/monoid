//! The MoonBit front (station/mb's program, `--builder mesh`): the station's iroh endpoint kept for its Node across
//! handovers, so an update binds no new endpoint and its relays stay linked (station/src/mesh/front.ts). The launcher
//! starts it before the first Node (or, taking up one from before it, before the Node of that handover) and keeps it as long as it runs: across Node's handovers and restarts, and across its
//! own `renew` (its pid and the pipe to its stdin handed on). Its stdin is that pipe: the launcher gone, it ends. Each Node
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
/// 4: a route's segment `*` is any one.
/// A front kept from before a raise here is replaced once by the launcher that takes it up (`current`): the one thing
/// that does not come with an update, as it is kept across them.
pub const STREAMS: u64 = 4;

pub struct Front {
    pub pid: i32,
    /// The write end of its stdin (never written: closed, it ends).
    input: OwnedFd,
    /// Where it listens.
    pub socket: PathBuf,
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
        let program = Front::program(app)?;
        let run = data.join("run");
        let socket = run.join("front.sock");
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
        // SAFETY: the pipe's write end, taken from the child's handle, owned here from now on.
        let input = unsafe { OwnedFd::from_raw_fd(child.stdin.take().unwrap().into_raw_fd()) };
        let mut out = child.stdout.take().unwrap();
        // Reaped by waitpid in run.rs's serve(), not by std.
        drop(child);
        match listening(&mut out) {
            Some((said, streams)) if said == socket.to_string_lossy() => {
                log::info(&format!("the front listens (pid {pid}): {}", socket.display()));
                Some(Front {
                    pid, input, socket, started: Some(Instant::now()), streams,
                    #[cfg(target_os = "macos")]
                    launcher_uuid: executable_uuid(),
                    #[cfg(target_os = "macos")]
                    uuid_recorded: true,
                })
            }
            other => {
                log::warn(&format!("the front (pid {pid}) did not listen ({other:?}); each Node binds the station's endpoint itself"));
                // SAFETY: a signal to a child of this process.
                unsafe { libc::kill(pid, libc::SIGKILL) };
                None
            }
        }
    }

    /// It ended: another in its place, unless it ended sooner than `lives` after it started (said; the lifecycle tries
    /// again later: `front_gone`).
    pub fn ended(self, app: &Path, data: &Path, how: &str, lives: Duration) -> Option<Front> {
        if let Some(started) = self.started.filter(|s| s.elapsed() < lives) {
            log::error(&format!("the front (pid {}) {how} {} ms after it started; not started again for now, Nodes bind the station's endpoint themselves meanwhile (the one serving hands over to one)", self.pid, started.elapsed().as_millis()));
            return None;
        }
        log::warn(&format!("the front (pid {}) {how}; starting another", self.pid));
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
        crate::run::cloexec_on(input);
        // SAFETY: the descriptor the launcher before handed on, owned by this one from here.
        Some(Front {
            pid, input: unsafe { OwnedFd::from_raw_fd(input) }, socket, started: None,
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
        None
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
/// (an operation it has none of, which it answers with an error and nothing else) and its answer read, then closed (it
/// parts with the connection as with a Node's that went: front/mesh.mbt `serve`, quietly). A connection alone would
/// not do: the system takes it into the socket's backlog whether or not the program runs.
pub fn answers(socket: &Path, within: Duration) -> bool {
    use std::io::{BufRead, BufReader, Write};
    let Some(stream) = connect_now(socket) else { return false };
    if stream.set_read_timeout(Some(within)).is_err() || stream.set_write_timeout(Some(within)).is_err() {
        return false;
    }
    if (&stream).write_all(b"{\"id\":1,\"op\":\"answers\"}\n").is_err() {
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
