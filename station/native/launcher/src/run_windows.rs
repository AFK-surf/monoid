//! `run` on Windows: the station's Node process under a launcher whose pid and lock stay. What happens to the Node
//! (ready, crashed and started again, stopped) is lifecycle.rs's, as on Unix; this is how Windows gives it its
//! processes and events, less what Windows cannot do the same way:
//!
//! - Node cannot listen on a socket handed down on Windows, so the launcher keeps the listening sockets and carries
//!   each connection to the Node serving (proxy.rs): a handover starts the new Node beside the old one, as on Unix.
//! - The control channel is a named pipe only this user may open, `\\.\pipe\stillfail-launcher-<pid>-<n>`, given as
//!   `--launcher-pipe`; on it the same lines go both ways as on Unix's socket.
//! - There are no signals: a ^C (or the console closing) stops the station, as SIGTERM does on Unix. Node runs in a
//!   process group of its own, so the ^C reaches the launcher only.
//!
//! Threads say what happened (Node's exit, a line from it, a ^C) on one channel; the main thread tells the lifecycle.
//!
//! An update brings a launcher too, at `<app>\mesh\target\release\stillfail-station.exe`, and Windows has no exec: at a
//! handover a launcher unlike it starts it (`renew`), hands it what it holds over a pipe of its own
//! (`\\.\pipe\stillfail-renew-<pid>`): the two listening sockets (WSADuplicateSocket), the Node serving (its control pipe's
//! handle duplicated, what it said and this one had not yet taken) and then the data directory's lock, and the new one
//! goes on with the handover (`--resume <that pipe>`, `resume`). This one takes no more connections, carries those it
//! has to their end (at most `LINGER`) and exits `RENEWED`, which stillfail-station-w (hidden.rs), the scheduled task's
//! process, takes for "follow the launcher run/renewed-to names". Only under a stillfail-station-w that does
//! (`FOLLOWED`): else the task would end with this one.

use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle};
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::ptr::{null, null_mut};
use std::collections::VecDeque;
use std::fs::File;
use std::hash::{DefaultHasher, Hasher};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;
use windows_sys::Win32::Foundation::{
    CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, GENERIC_READ, GENERIC_WRITE, GetLastError, HANDLE,
    INVALID_HANDLE_VALUE, LocalFree, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows_sys::Win32::Security::{GetTokenInformation, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows_sys::Win32::Storage::FileSystem::{CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING, PIPE_ACCESS_DUPLEX, ReadFile, WriteFile};
use windows_sys::Win32::System::Console::SetConsoleCtrlHandler;
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::{ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT};
use windows_sys::Win32::System::Threading::{
    CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, CreateEventW, GetCurrentProcess, GetExitCodeProcess, OpenProcess, OpenProcessToken,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, TerminateProcess, WaitForSingleObject,
};

use crate::data::{self, Config};
use crate::lifecycle::{Lifecycle, Os, Process, Times};
use crate::proxy::Entrance;
pub use crate::lifecycle::Options;
use crate::log;

enum Event {
    /// Node `pid` exited, with this code.
    Exited(u32, Option<i32>),
    /// Node `pid` said this.
    Said(u32, Value),
    Stop(&'static str),
    /// Asked on the launcher's own pipe (control_pipe): handover, drain, hup, stop (Unix's SIGUSR2, SIGUSR1, SIGHUP,
    /// SIGTERM).
    Ask(String),
}

/// How long a connection to an entrance waits for a Node to serve it (a handover's moment, a restart) before it is
/// closed.
const ENTRANCE_WAIT: Duration = Duration::from_secs(60);

/// Where the release has its launcher (scripts/station-bundle.sh), which takes this one's place where it is not this one.
const LAUNCHER_IN_APP: &str = "mesh/target/release/stillfail-station.exe";
/// What a launcher's `handoff-version` says from when it takes a running one's place on Windows (`--resume <pipe>`).
const TAKES_OVER: u32 = 4;
/// Set by stillfail-station-w (hidden.rs) where it follows a launcher that took its child's place (`RENEWED`): only
/// there does a launcher hand on and end.
pub const FOLLOWED: &str = "STILLFAIL_LAUNCHER_FOLLOWED";
/// The exit of a launcher whose place the release's took; run/renewed-to names it (the scheduled task's process follows).
pub const RENEWED: i32 = 75;
pub const RENEWED_TO: &str = "renewed-to";
/// How long a launcher whose place was taken carries what it carried already (an agent's call, a page's request).
const LINGER: Duration = Duration::from_secs(600);
/// How long the release's launcher may take to open the renew pipe and take up what it is handed.
const RENEW_WITHIN: Duration = Duration::from_secs(20);

/// The launcher's own pipe, by its pid (run/station.json's): what the installer and the CLI ask it on, one
/// `{"op":…}` a line. Only this user may open it.
pub fn control_pipe(pid: u32) -> String {
    format!(r"\\.\pipe\stillfail-launcher-{pid}")
}

static EVENTS: OnceLock<Mutex<Sender<Event>>> = OnceLock::new();

/// ^C, ^Break, the console closing, the user logging off: the station stops.
unsafe extern "system" fn on_ctrl(_kind: u32) -> i32 {
    if let Some(events) = EVENTS.get() {
        let _ = events.lock().unwrap_or_else(|e| e.into_inner()).send(Event::Stop("a console event"));
    }
    1
}

struct Node {
    pid: u32,
    /// Waited on, ended (TerminateProcess).
    process: Arc<OwnedHandle>,
    pipe: Pipe,
    /// The thread reading its lines (read_lines): stopped (`stop`, the pipe's read called off) for a renew, it gives
    /// back what it read of a line not ended yet.
    reading: Mutex<Option<JoinHandle<Vec<u8>>>>,
    stop: Arc<AtomicBool>,
}

impl Process for Node {
    fn pid(&self) -> u32 {
        self.pid
    }

    fn send(&self, line: &serde_json::Value) {
        if let Err(error) = self.pipe.write_all(format!("{line}\n").as_bytes()) {
            log::warn(&format!("Node {} not told: {error}", self.pid));
        }
    }
}

impl Node {
    /// Node `pid` (`process`) on `pipe`, its end and lines told on `tx` by threads of their own: `connected`, the pipe
    /// is (a Node a launcher before this one handed on); `pending`, what was read of a line not ended yet.
    fn watched(pid: u32, process: OwnedHandle, pipe: Pipe, tx: &Sender<Event>, connected: bool, pending: Vec<u8>) -> Node {
        let process = Arc::new(process);
        let (theirs, wait_pipe, exited) = (process.clone(), pipe.clone(), tx.clone());
        std::thread::spawn(move || {
            // SAFETY: waiting on our handle.
            unsafe { WaitForSingleObject(theirs.as_raw_handle() as HANDLE, u32::MAX) };
            // A pipe it never connected to waits no more.
            wait_pipe.cancel();
            let code = exit_code(&theirs);
            let _ = exited.send(Event::Exited(pid, code));
        });
        let stop = Arc::new(AtomicBool::new(false));
        let (read_pipe, said, stopping) = (pipe.clone(), tx.clone(), stop.clone());
        let reading = std::thread::spawn(move || read_lines(pid, read_pipe, said, stopping, connected, pending));
        Node { pid, process, pipe, reading: Mutex::new(Some(reading)), stop }
    }

    /// Its lines no longer read here (a renew): what was read of a line not ended yet. None: the thread had ended.
    fn stop_reading(&self) -> Option<Vec<u8>> {
        let reading = self.reading.lock().unwrap_or_else(|e| e.into_inner()).take()?;
        self.stop.store(true, Ordering::SeqCst);
        // (a read called off as it waits; one begun just after is called off as this comes round again)
        while !reading.is_finished() {
            self.pipe.cancel();
            std::thread::yield_now();
        }
        reading.join().ok()
    }
}

/// Windows' processes: each Node with a pipe of its own, its lines and its exit told on the channel by threads.
struct System {
    options: Options,
    security: Arc<Security>,
    tx: Sender<Event>,
    /// What threads say (serve), and what was taken off it for a renew that did not happen, to be told first.
    rx: Receiver<Event>,
    deferred: VecDeque<Event>,
    /// The data directory's lock, let go once a launcher that took this one's place asks for it (renew).
    lock: Option<File>,
    /// This launcher's own (the release's at --app as it started), against which the release's is told new.
    own: Option<u64>,
    next: u64,
    /// --with-parent: the parent at the start, to wait on.
    parent: Option<OwnedHandle>,
    /// The ports the launcher holds (the agents' MCP endpoint's, the loopback port's), as Node is told them, and their
    /// entrances: each carried to the Node serving it (proxy.rs).
    ports: (u16, u16),
    mcp: Entrance,
    admin: Entrance,
}

impl Os for System {
    type Node = Node;

    fn now(&self) -> Instant {
        Instant::now()
    }

    fn spawn(&mut self) -> io::Result<Node> {
        self.next += 1;
        let name = format!(r"\\.\pipe\stillfail-launcher-{}-{}", std::process::id(), self.next);
        let pipe = Pipe::create(&name, &self.security).map_err(|error| io::Error::new(error.kind(), format!("{name}: {error}")))?;
        let app = &self.options.app;
        let mut command = crate::station(app).command();
        // Node listens where it may (127.0.0.1, any port) and says where once it serves; the launcher's ports, which
        // agents and the CLI are told, it is given to say as its own.
        let ports = format!("{},{}", self.ports.0, self.ports.1);
        command.arg("run").arg("--app").arg(app).arg("--data").arg(&self.options.data).arg("--launcher-pipe").arg(&name).arg("--launcher-ports").arg(ports);
        // What it holds only in memory (the vault's grants) carried to the next at a handover, and its heartbeat, as
        // on Unix (lifecycle.rs takes both from either; tests/node_flags.rs holds the two to what Node reads).
        command.args(["--launcher-carries", "--launcher-heartbeat"]);
        command.stdin(Stdio::null()).creation_flags(CREATE_NEW_PROCESS_GROUP);
        let mut child = command.spawn()?;
        let pid = child.id();
        // Its exit, seen from a thread of its own: a handle of its process to wait on (and to end it by).
        let Some(process) = open_process(pid, PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE) else {
            let error = io::Error::last_os_error();
            let _ = child.kill();
            return Err(io::Error::new(error.kind(), format!("Node {pid} cannot be waited for: {error}")));
        };
        let _ = child.stdin.take();
        Ok(Node::watched(pid, process, pipe, &self.tx, false, vec![]))
    }

    fn kill(&mut self, node: &mut Node) {
        // Its exit is told by its waiting thread, as any.
        // SAFETY: on our handle of its process.
        unsafe { TerminateProcess(node.process.as_raw_handle() as HANDLE, 1) };
    }

    fn parent_gone(&mut self) -> bool {
        // The parent's pid is not taken over on Windows (a child keeps naming a parent long gone): its process is
        // waited on instead. None to wait on: gone already.
        match &self.parent {
            // SAFETY: waiting on our handle, not at all.
            Some(parent) => unsafe { WaitForSingleObject(parent.as_raw_handle() as HANDLE, 0) != WAIT_TIMEOUT },
            None => true,
        }
    }

    fn program(&self) -> String {
        crate::station(&self.options.app).program.display().to_string()
    }

    fn route(&mut self, name: &str, port: Option<u16>) {
        match name {
            "mcp" => self.mcp.serve(port),
            "admin" => self.admin.serve(port),
            _ => log::warn(&format!("Node serves {name}, which the launcher has no entrance for")),
        }
    }

    fn renew(&mut self, serving: &Node, version: &str, served: &[(String, u16)], heartbeats: bool) -> bool {
        if std::env::var_os(FOLLOWED).is_none() {
            return false;
        }
        let release = self.options.app.join(LAUNCHER_IN_APP);
        let Some(theirs) = hash_of(&release) else { return false };
        if self.own == Some(theirs) {
            return false;
        }
        // One from before it could take over on Windows (a release rolled back to) hands over as it is.
        let takes = Command::new(&release).arg("handoff-version").stdin(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW).output();
        let version_said = takes.ok().filter(|o| o.status.success()).and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<u32>().ok());
        if version_said.is_none_or(|v| v < TAKES_OVER) {
            log::warn(&format!("the release's launcher ({}) cannot take this one's place; this one hands over", release.display()));
            return false;
        }
        match self.hand_on(&release, serving, version, served, heartbeats) {
            Ok(()) => true,
            Err(why) => {
                log::warn(&format!("the release's launcher did not take this one's place ({why}); this one hands over"));
                false
            }
        }
    }
}

impl System {
    /// Hands what this launcher holds to the release's launcher at `release`, which goes on with the handover; Err:
    /// nothing handed (what was taken back as it was), this one goes on.
    fn hand_on(&mut self, release: &Path, serving: &Node, version: &str, served: &[(String, u16)], heartbeats: bool) -> Result<(), String> {
        let name = renew_pipe(std::process::id());
        let pipe = Pipe::create(&name, &self.security).map_err(|e| format!("{name}: {e}"))?;
        // Its lines no longer read here: what it said that this one has not taken yet goes with it.
        let pending = serving.stop_reading().unwrap_or_default();
        let mut said = vec![];
        let mut gone = false;
        while let Ok(event) = self.rx.try_recv() {
            match event {
                Event::Said(pid, message) if pid == serving.pid => said.push(message),
                Event::Exited(pid, _) if pid == serving.pid => {
                    gone = true;
                    self.deferred.push_back(event);
                }
                other => self.deferred.push_back(other),
            }
        }
        let undo = |this: &mut System, pending: Vec<u8>, said: Vec<Value>| {
            // (what it said goes first, then what comes after: the lines read again from the pipe from here)
            let mut first: VecDeque<Event> = said.into_iter().map(|m| Event::Said(serving.pid, m)).collect();
            first.extend(this.deferred.drain(..));
            this.deferred = first;
            let stop = serving.stop.clone();
            stop.store(false, Ordering::SeqCst);
            let (read_pipe, tx) = (serving.pipe.clone(), this.tx.clone());
            let pid = serving.pid;
            *serving.reading.lock().unwrap_or_else(|e| e.into_inner()) = Some(std::thread::spawn(move || read_lines(pid, read_pipe, tx, stop, true, pending)));
        };
        if gone {
            undo(self, pending, said);
            return Err("the Node serving ended meanwhile".into());
        }
        let mut args: Vec<std::ffi::OsString> = vec![];
        let mut given = std::env::args_os().skip(1);
        while let Some(arg) = given.next() {
            if arg == "--resume" {
                given.next();
            } else {
                args.push(arg);
            }
        }
        args.extend(["--resume".into(), name.clone().into()]);
        log::info(&format!("the release has a new launcher; it takes this one's place ({})", release.display()));
        let mut child = match Command::new(release).args(&args).stdin(Stdio::null()).creation_flags(CREATE_NO_WINDOW).spawn() {
            Ok(child) => child,
            Err(error) => {
                undo(self, pending, said);
                return Err(format!("it did not start: {error}"));
            }
        };
        let theirs = child.id();
        let handed = (|| -> Result<(), String> {
            // It opens the pipe (or ends) within RENEW_WITHIN: else what waits on it is called off.
            let connected = pipe.clone();
            let (done, connect) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = done.send(connected.connect());
            });
            match connect.recv_timeout(RENEW_WITHIN) {
                Ok(Ok(())) => {}
                Ok(Err(error)) => return Err(format!("{name} not opened: {error}")),
                Err(_) => {
                    pipe.cancel();
                    return Err(format!("{name} not opened within {} s", RENEW_WITHIN.as_secs()));
                }
            }
            let mcp = self.mcp.hand(theirs).map_err(|e| format!("the MCP endpoint's socket: {e}"))?;
            let admin = self.admin.hand(theirs).map_err(|e| format!("the loopback port's socket: {e}"))?;
            let control = duplicate_to(serving.pipe.raw(), child.as_raw_handle() as HANDLE).map_err(|e| format!("the Node's pipe: {e}"))?;
            let state = serde_json::json!({
                "from": std::process::id(),
                "ports": [self.ports.0, self.ports.1],
                "mcp": hex(&mcp),
                "admin": hex(&admin),
                "node": {"pid": serving.pid, "control": control as usize as u64, "pending": &pending, "said": &said, "version": version, "served": served, "heartbeats": heartbeats},
            });
            pipe.write_all(format!("{state}\n").as_bytes()).map_err(|e| format!("{name}: {e}"))?;
            match read_line(&pipe).map_err(|e| format!("{name}: {e}"))?.get("took") {
                Some(Value::Bool(true)) => Ok(()),
                _ => Err("it did not take what it was handed".into()),
            }
        })();
        if let Err(why) = handed {
            let _ = child.kill();
            undo(self, pending, said);
            return Err(why);
        }
        // Taken: no more connections here, and the lock let go for it to take.
        self.mcp.stop();
        self.admin.stop();
        self.lock = None;
        let _ = pipe.write_all(b"{\"unlocked\":true}\n");
        let run = self.options.data.join("run");
        if let Err(error) = data::write_whole(&run.join(RENEWED_TO), &format!("{theirs}\n")) {
            log::warn(&format!("{RENEWED_TO} not written: {error}"));
        }
        Ok(())
    }

    /// Whether this launcher still carries a connection (its place taken: it lingers for them).
    fn carrying(&self) -> bool {
        self.mcp.carrying() + self.admin.carrying() > 0
    }
}

/// The pipe a launcher hands what it holds on, to the release's launcher taking its place.
fn renew_pipe(pid: u32) -> String {
    format!(r"\\.\pipe\stillfail-renew-{pid}")
}

/// A handle of ours duplicated into process `target`: its value there.
fn duplicate_to(handle: HANDLE, target: HANDLE) -> io::Result<HANDLE> {
    let mut theirs: HANDLE = null_mut();
    // SAFETY: handles of ours; what is made is the target's, which takes it up by its value.
    if unsafe { DuplicateHandle(GetCurrentProcess(), handle, target, &mut theirs, 0, 0, DUPLICATE_SAME_ACCESS) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(theirs)
}

fn open_process(pid: u32, access: u32) -> Option<OwnedHandle> {
    // SAFETY: a handle of ours, closed by OwnedHandle.
    let process = unsafe { OpenProcess(access, 0, pid) };
    (!process.is_null()).then(|| unsafe { OwnedHandle::from_raw_handle(process as RawHandle) })
}

fn hash_of(path: &Path) -> Option<u64> {
    let bytes = std::fs::read(path).ok()?;
    let mut hasher = DefaultHasher::new();
    hasher.write(&bytes);
    Some(hasher.finish())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    (0..text.len()).step_by(2).map(|i| text.get(i..i + 2).and_then(|b| u8::from_str_radix(b, 16).ok())).collect()
}

/// One line read from `pipe`, as JSON.
fn read_line(pipe: &Pipe) -> io::Result<Value> {
    let mut line = vec![];
    let mut byte = [0u8; 1];
    loop {
        match pipe.read(&mut byte)? {
            0 => return Err(io::ErrorKind::UnexpectedEof.into()),
            _ if byte[0] == b'\n' => break,
            _ => line.push(byte[0]),
        }
    }
    serde_json::from_slice(&line).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

pub fn run(mut options: Options) -> i32 {
    let run = options.data.join("run");
    if let Some(name) = options.resume.take() {
        return resume(options, run, &name);
    }
    if let Err(error) = std::fs::create_dir_all(&run) {
        log::error(&format!("{}: {error}", run.display()));
        return 1;
    }
    let config = match Config::read(&options.data) {
        Ok(config) => config,
        Err(error) => {
            log::error(&format!("the config does not read: {error}"));
            return 1;
        }
    };
    let lock = match data::lock(&run.join("station.lock")) {
        Ok(Some(lock)) => lock,
        Ok(None) => {
            let dir = options.data.display();
            if config.english {
                eprintln!("Another still.fail station is running on this data directory ({dir}); only one station can run on a data directory on one machine");
            } else {
                eprintln!("另一个 still.fail station 正在运行这个数据目录（{dir}）；同一台机器上的一个数据目录只能运行一个 station");
            }
            return crate::HELD;
        }
        Err(error) => {
            log::error(&format!("{}: {error}", run.join("station.lock").display()));
            return 1;
        }
    };
    let _ = std::fs::remove_file(run.join("drained"));
    // The ports, held by the launcher for good (as on Unix), so a handover keeps them: Node serves behind them.
    let bound = {
        // Only the machine's own data directory has the usual ports (ports.rs).
        let own = data::is_default(&data::home(), &options.data);
        crate::ports::mcp(&options.data, &config, own).and_then(|mcp| Ok((mcp, crate::ports::admin(&options.data, options.port, options.named, own, config.english)?)))
    };
    let (mcp, admin) = match bound {
        Ok(bound) => bound,
        Err(error) => {
            log::error(&error);
            eprintln!("{error}");
            return 1;
        }
    };
    let port_of = |l: &std::net::TcpListener| l.local_addr().map(|a| a.port()).unwrap_or(0);
    let ports = (port_of(&mcp), port_of(&admin));
    let (mcp, admin) = (Entrance::open("the agents' MCP endpoint", mcp, ENTRANCE_WAIT), Entrance::open("the loopback port", admin, ENTRANCE_WAIT));
    let security = match Security::this_user() {
        Ok(security) => Arc::new(security),
        Err(error) => {
            log::error(&error);
            return 1;
        }
    };
    let (tx, rx) = mpsc::channel();
    let _ = EVENTS.set(Mutex::new(tx.clone()));
    // SAFETY: a handler that only sends on a channel.
    unsafe { SetConsoleCtrlHandler(Some(on_ctrl), 1) };
    let with_parent = options.with_parent;
    let parent = if with_parent { parent_process() } else { None };
    if with_parent && parent.is_none() {
        log::warn("--with-parent: the parent is not there");
    }
    if let Err(error) = take_asks(&security, tx.clone()) {
        log::error(&format!("{}: {error}", control_pipe(std::process::id())));
        return 1;
    }
    // (a renewed-to left by a launcher before this start names none of this one's)
    let _ = std::fs::remove_file(run.join(RENEWED_TO));
    let own = hash_of(&options.app.join(LAUNCHER_IN_APP));
    let system = System { options, security, tx, rx, deferred: VecDeque::new(), lock: Some(lock), own, next: 0, parent, ports, mcp, admin };
    let mut station = Lifecycle::new(system, Times::of_env(), run, with_parent);
    station.start();
    serve(&mut station)
}

/// A launcher before this one started it to take its place at a handover (`renew`): what it hands on taken up on the
/// pipe `name` (its listening sockets, the Node serving), then its lock, and the handover it was asked for gone on with.
fn resume(options: Options, run: PathBuf, name: &str) -> i32 {
    let pipe = match Pipe::open(name) {
        Ok(pipe) => pipe,
        Err(error) => {
            log::error(&format!("{name}: {error}"));
            return 1;
        }
    };
    let state = match read_line(&pipe) {
        Ok(state) => state,
        Err(error) => {
            log::error(&format!("what the launcher before this one handed on does not read: {error}"));
            return 1;
        }
    };
    let security = match Security::this_user() {
        Ok(security) => Arc::new(security),
        Err(error) => {
            log::error(&error);
            return 1;
        }
    };
    let (tx, rx) = mpsc::channel();
    let Some(taken) = Taken::read(&state, &tx) else {
        // Nothing to go on with: the launcher before goes on as it was.
        log::error("what the launcher before this one handed on does not read; stopping");
        return 1;
    };
    if pipe.write_all(b"{\"took\":true}\n").is_err() {
        log::error("the launcher before this one went before it was told");
        return 1;
    }
    // Its lock, once it let it go.
    let lock = match read_line(&pipe).ok().and_then(|v| v.get("unlocked").cloned()) {
        Some(Value::Bool(true)) => match data::lock(&run.join("station.lock")) {
            Ok(Some(lock)) => Some(lock),
            Ok(None) => {
                log::warn("the data directory's lock is held by another process; going on without it");
                None
            }
            Err(error) => {
                log::warn(&format!("the data directory's lock: {error}"));
                None
            }
        },
        _ => {
            log::warn("the launcher before this one did not let its lock go; going on without it");
            None
        }
    };
    let _ = EVENTS.set(Mutex::new(tx.clone()));
    // SAFETY: a handler that only sends on a channel.
    unsafe { SetConsoleCtrlHandler(Some(on_ctrl), 1) };
    let with_parent = options.with_parent;
    let parent = if with_parent { parent_process() } else { None };
    if let Err(error) = take_asks(&security, tx.clone()) {
        log::error(&format!("{}: {error}", control_pipe(std::process::id())));
        return 1;
    }
    let own = hash_of(&options.app.join(LAUNCHER_IN_APP));
    let Taken { from, ports, mcp, admin, node, said, version, served, heartbeats } = taken;
    log::info(&format!("this launcher takes the place of launcher {from}"));
    let pid = node.pid;
    let system = System { options, security, tx, rx, deferred: VecDeque::new(), lock, own, next: 0, parent, ports, mcp, admin };
    let mut station = Lifecycle::new(system, Times::of_env(), run, with_parent);
    station.renewed_from(from);
    station.adopt(node, version, served, heartbeats);
    if !said.is_empty() {
        station.heard(pid, said);
    }
    station.start_next();
    serve(&mut station)
}

/// What a launcher before this one handed on (`hand_on`).
struct Taken {
    from: u32,
    ports: (u16, u16),
    mcp: Entrance,
    admin: Entrance,
    node: Node,
    said: Vec<Value>,
    version: String,
    served: Vec<(String, u16)>,
    heartbeats: bool,
}

impl Taken {
    fn read(state: &Value, tx: &Sender<Event>) -> Option<Taken> {
        let from = u32::try_from(state["from"].as_u64()?).ok()?;
        let port = |i: usize| state["ports"][i].as_u64().and_then(|p| u16::try_from(p).ok());
        let ports = (port(0)?, port(1)?);
        let node = &state["node"];
        let pid = u32::try_from(node["pid"].as_u64()?).ok()?;
        let control = node["control"].as_u64()? as usize as HANDLE;
        let pending: Vec<u8> = serde_json::from_value(node["pending"].clone()).ok()?;
        let said: Vec<Value> = serde_json::from_value(node["said"].clone()).ok()?;
        let served: Vec<(String, u16)> = serde_json::from_value(node["served"].clone()).ok()?;
        let version = node["version"].as_str()?.to_string();
        let heartbeats = node["heartbeats"].as_bool().unwrap_or(false);
        let mcp = Entrance::taken("the agents' MCP endpoint", &unhex(state["mcp"].as_str()?)?, ENTRANCE_WAIT).map_err(|e| log::error(&format!("{e}"))).ok()?;
        let admin = Entrance::taken("the loopback port", &unhex(state["admin"].as_str()?)?, ENTRANCE_WAIT).map_err(|e| log::error(&format!("{e}"))).ok()?;
        let process = open_process(pid, PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE)?;
        // SAFETY: the handle the launcher before duplicated into this process for it, ours from here.
        let pipe = Pipe(Arc::new(unsafe { OwnedHandle::from_raw_handle(control as RawHandle) }));
        let node = Node::watched(pid, process, pipe, tx, true, pending);
        Some(Taken { from, ports, mcp, admin, node, said, version, served, heartbeats })
    }
}

/// The launcher's own pipe (control_pipe), taking one asker at a time: each line's op told on the channel.
fn take_asks(security: &Security, tx: Sender<Event>) -> io::Result<()> {
    let pipe = Pipe::create(&control_pipe(std::process::id()), security)?;
    std::thread::spawn(move || {
        loop {
            if pipe.connect().is_ok() {
                let mut pending = Vec::new();
                let mut buf = [0u8; 1024];
                while let Ok(got) = pipe.read(&mut buf).and_then(|n| if n == 0 { Err(io::ErrorKind::UnexpectedEof.into()) } else { Ok(n) }) {
                    pending.extend_from_slice(&buf[..got]);
                    while let Some(at) = pending.iter().position(|&b| b == b'\n') {
                        let line: Vec<u8> = pending.drain(..=at).collect();
                        match serde_json::from_slice::<Value>(&line).ok().and_then(|v| v["op"].as_str().map(str::to_string)) {
                            Some(op) => {
                                let _ = tx.send(Event::Ask(op));
                            }
                            None => log::warn(&format!("asked what the launcher does not read: {}", String::from_utf8_lossy(&line).trim())),
                        }
                    }
                }
            }
            // The asker gone (or never there): the next one.
            pipe.disconnect();
        }
    });
    Ok(())
}

/// Waits for what happens (a line from a Node, a Node's end, a stop, something due) and tells the lifecycle, until it
/// is done.
fn serve(station: &mut Lifecycle<System>) -> i32 {
    loop {
        if let Some(exit) = station.finished() {
            log::info("stopped");
            return exit;
        }
        if station.renewed() {
            return linger(&station.os);
        }
        let event = match station.os.deferred.pop_front() {
            Some(event) => Some(event),
            None => match station.next_due() {
                Some(at) => match station.os.rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(event) => Some(event),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return 1,
                },
                None => match station.os.rx.recv() {
                    Ok(event) => Some(event),
                    Err(_) => return 1,
                },
            },
        };
        match event {
            Some(Event::Said(pid, message)) => station.heard(pid, vec![message]),
            Some(Event::Exited(pid, code)) => station.ended(pid, &code.map_or("exited (no code)".into(), |c| format!("exited with {c}"))),
            Some(Event::Stop(why)) => {
                log::info(&format!("stopping ({why})"));
                station.stop();
            }
            Some(Event::Ask(op)) => match op.as_str() {
                "handover" => station.start_next(),
                "drain" | "hup" => station.ask(&op),
                "stop" => {
                    log::info("stopping (asked)");
                    station.stop();
                }
                _ => log::warn(&format!("asked to {op}, which the launcher does not do")),
            },
            None => {}
        }
        // (its place taken in what was just done: nothing more is done here, the lifecycle's deadlines included)
        if station.renewed() {
            return linger(&station.os);
        }
        station.tick();
    }
}

/// Its place taken (renew): what it carries carried to its end (at most LINGER), then `RENEWED`. What else comes (the
/// Node's lines, an ask on its pipe) is the launcher's that took its place now.
fn linger(system: &System) -> i32 {
    let until = Instant::now() + LINGER;
    while system.carrying() && Instant::now() < until {
        // (nothing tells this process when a connection it carries ends but the connection's own thread: a look now
        // and then while one is carried)
        std::thread::sleep(Duration::from_millis(200));
    }
    log::info("the release's launcher took this one's place; this one ends");
    RENEWED
}

fn exit_code(process: &OwnedHandle) -> Option<i32> {
    let mut code = 0u32;
    // SAFETY: on our handle of the exited process.
    let ok = unsafe { GetExitCodeProcess(process.as_raw_handle() as HANDLE, &mut code) };
    (ok != 0).then_some(code as i32)
}

/// Lines from Node on the pipe, once it has connected (`connected`: it is already, a Node handed on, `pending` what
/// was read of a line before); until it closes, or until `stop` (a renew), which gives back what was read of a line
/// not ended yet.
fn read_lines(pid: u32, pipe: Pipe, tx: Sender<Event>, stop: Arc<AtomicBool>, connected: bool, mut pending: Vec<u8>) -> Vec<u8> {
    if !connected && pipe.connect().is_err() {
        return pending;
    }
    let mut buf = [0u8; 4096];
    loop {
        if stop.load(Ordering::SeqCst) {
            return pending;
        }
        let got = match pipe.read(&mut buf) {
            Ok(0) => return pending,
            Err(_) => return pending,
            Ok(got) => got,
        };
        pending.extend_from_slice(&buf[..got]);
        while let Some(at) = pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = pending.drain(..=at).collect();
            match serde_json::from_slice::<Value>(&line) {
                Ok(message) => {
                    let _ = tx.send(Event::Said(pid, message));
                }
                Err(_) => log::warn(&format!("an unreadable line from Node: {}", String::from_utf8_lossy(&line).trim())),
            }
        }
    }
}

/// --with-parent: the launcher's parent, to wait on (its pid read now, while it is still the parent's).
fn parent_process() -> Option<OwnedHandle> {
    let parent = parent_pid()?;
    // SAFETY: a handle of ours, closed by OwnedHandle.
    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, parent) };
    (!process.is_null()).then(|| unsafe { OwnedHandle::from_raw_handle(process as RawHandle) })
}

fn parent_pid() -> Option<u32> {
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS};
    let me = std::process::id();
    // SAFETY: a snapshot of ours, closed after; the entry's size set as the API wants.
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return None;
        }
        let snapshot = OwnedHandle::from_raw_handle(snapshot as RawHandle);
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
        let mut more = Process32FirstW(snapshot.as_raw_handle() as HANDLE, &mut entry) != 0;
        while more {
            if entry.th32ProcessID == me {
                return Some(entry.th32ParentProcessID);
            }
            more = Process32NextW(snapshot.as_raw_handle() as HANDLE, &mut entry) != 0;
        }
        None
    }
}

fn wide(text: &str) -> Vec<u16> {
    OsStr::new(text).encode_wide().chain(Some(0)).collect()
}

/// A security descriptor letting this user alone open the pipe (as the runner's).
struct Security(*mut std::ffi::c_void);

// SAFETY: read only, by CreateNamedPipeW.
unsafe impl Send for Security {}
unsafe impl Sync for Security {}

impl Security {
    fn this_user() -> Result<Security, String> {
        let failed = |what: &str| format!("{what}: {}", io::Error::last_os_error());
        // SAFETY: the token and buffers are ours; what Windows allocates is freed with LocalFree.
        unsafe {
            let mut token = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(failed("OpenProcessToken"));
            }
            let token = OwnedHandle::from_raw_handle(token as RawHandle);
            let mut size = 0;
            GetTokenInformation(token.as_raw_handle() as HANDLE, TokenUser, null_mut(), 0, &mut size);
            let mut buf = vec![0u64; (size as usize).div_ceil(8)];
            if GetTokenInformation(token.as_raw_handle() as HANDLE, TokenUser, buf.as_mut_ptr().cast(), size, &mut size) == 0 {
                return Err(failed("GetTokenInformation"));
            }
            let user = &*(buf.as_ptr() as *const TOKEN_USER);
            let mut sid = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
                return Err(failed("ConvertSidToStringSidW"));
            }
            let len = (0..).take_while(|&i| *sid.add(i) != 0).count();
            let sid_text = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
            LocalFree(sid.cast());
            let sddl = wide(&format!("D:P(A;;GA;;;{sid_text})"));
            let mut descriptor = null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut()) == 0 {
                return Err(failed("ConvertStringSecurityDescriptorToSecurityDescriptorW"));
            }
            Ok(Security(descriptor))
        }
    }
}

impl Drop for Security {
    fn drop(&mut self) {
        // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(self.0) };
    }
}

/// One instance of a named pipe for one Node, opened for overlapped I/O (a read waiting does not hold up a write).
#[derive(Clone)]
struct Pipe(Arc<OwnedHandle>);

impl Pipe {
    fn create(name: &str, security: &Security) -> io::Result<Pipe> {
        let attributes = SECURITY_ATTRIBUTES { nLength: size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: security.0, bInheritHandle: 0 };
        let name = wide(name);
        // SAFETY: a name and attributes that live through the call.
        let handle = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                4096,
                4096,
                0,
                &attributes,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: just made, ours alone.
        Ok(Pipe(Arc::new(unsafe { OwnedHandle::from_raw_handle(handle as RawHandle) })))
    }

    /// The client's end of the pipe `name` (a renew's, opened by the launcher taking the place of the one that made it).
    fn open(name: &str) -> io::Result<Pipe> {
        let name = wide(name);
        // SAFETY: a name that lives through the call; the handle is ours.
        let handle = unsafe { CreateFileW(name.as_ptr(), GENERIC_READ | GENERIC_WRITE, 0, null(), OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null_mut()) };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: just opened, ours alone.
        Ok(Pipe(Arc::new(unsafe { OwnedHandle::from_raw_handle(handle as RawHandle) })))
    }

    fn raw(&self) -> HANDLE {
        self.0.as_raw_handle() as HANDLE
    }

    fn connect(&self) -> io::Result<()> {
        self.overlapped(|h, o| unsafe { ConnectNamedPipe(h, o) }, |e| e == ERROR_PIPE_CONNECTED).map(|_| ())
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        let len = buf.len() as u32;
        // SAFETY: the buffer outlives the operation (`overlapped` waits for its end).
        self.overlapped(|h, o| unsafe { ReadFile(h, buf.as_mut_ptr(), len, null_mut(), o) }, |_| false)
    }

    fn write_all(&self, mut buf: &[u8]) -> io::Result<()> {
        while !buf.is_empty() {
            let len = buf.len() as u32;
            // SAFETY: as in read.
            let n = self.overlapped(|h, o| unsafe { WriteFile(h, buf.as_ptr(), len, null_mut(), o) }, |_| false)?;
            if n == 0 {
                return Err(io::ErrorKind::WriteZero.into());
            }
            buf = &buf[n..];
        }
        Ok(())
    }

    /// Ends what waits on it (a connect Node will never make).
    fn cancel(&self) {
        // SAFETY: on our own handle.
        unsafe { CancelIoEx(self.raw(), null()) };
    }

    /// Lets the client go, for the next one to connect.
    fn disconnect(&self) {
        // SAFETY: on our own handle.
        unsafe { DisconnectNamedPipe(self.raw()) };
    }

    fn overlapped(&self, start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> i32, done: impl Fn(u32) -> bool) -> io::Result<usize> {
        // SAFETY: the event and the OVERLAPPED live until the operation has ended (GetOverlappedResult waits for it).
        unsafe {
            let event = CreateEventW(null(), 1, 0, null());
            if event.is_null() {
                return Err(io::Error::last_os_error());
            }
            let mut o: OVERLAPPED = std::mem::zeroed();
            o.hEvent = event;
            let result = (|| {
                if start(self.raw(), &mut o) == 0 {
                    let error = GetLastError();
                    if done(error) {
                        return Ok(0);
                    }
                    if error != ERROR_IO_PENDING {
                        return Err(io::Error::from_raw_os_error(error as i32));
                    }
                }
                let mut n = 0;
                if GetOverlappedResult(self.raw(), &o, &mut n, 1) == 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(n as usize)
            })();
            CloseHandle(event);
            result
        }
    }
}
