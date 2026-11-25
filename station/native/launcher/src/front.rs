//! The mesh front (`--builder mesh`): the station's iroh endpoint kept for its Node across handovers, so an update
//! binds no new endpoint and its relays stay linked (station/src/mesh/front.ts). Runs MoonBit (`stillfail-reader`,
//! default) or Pion (`stillfail-pion`) selected by `STILLFAIL_READER_MESH` > `<data>/config.json` `readers.mesh` >
//! `STILLFAIL_READER_ENGINE` > `"mb"` (matching `station/src/read/reader-select.ts`), taking effect on startup,
//! `SIGUSR2` handover, and launcher `renew`. The launcher starts it before the first Node (or, taking up one from
//! before it, before the Node of that handover) and keeps it as long as it runs: across Node's handovers and restarts,
//! and across its own `renew` (its pid, engine, and the pipe to its stdin handed on). Its stdin is that pipe: the
//! launcher gone, it ends; the launcher stopping kills one that does not (`end`), and one left from before (no
//! launcher's, beside the one kept) is found by its pid file and its arguments and killed (`clean_orphans`). Each Node
//! is told where it listens (STILLFAIL_MESH_FRONT); where none could be started, a Node binds the endpoint itself as
//! before (the mesh addon). Unix only: the front listens on a Unix socket.

use std::ffi::{CString, OsStr};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::log;

/// Where the release has the MoonBit program (beside the station's main.js, as station/src/read/mb-reader.ts finds it).
const PROGRAM_IN_APP: &str = "station/stillfail-reader";
/// The MoonBit program to run instead of the release's (development, tests: as mb-reader.ts reads it).
const PROGRAM_VAR: &str = "STILLFAIL_MB_READER";
/// Where the release has the Pion program (beside stillfail-reader).
const PION_PROGRAM_IN_APP: &str = "station/stillfail-pion";
/// The Pion program to run instead of the release's (development, tests: as mb-reader.ts reads it).
const PION_PROGRAM_VAR: &str = "STILLFAIL_PION_READER";
/// Per-mode engine override for `--builder mesh` (matches station/src/read/reader-select.ts).
const MESH_ENGINE_VAR: &str = "STILLFAIL_READER_MESH";
/// Global reader engine override (matches station/src/read/reader-select.ts).
const GLOBAL_ENGINE_VAR: &str = "STILLFAIL_READER_ENGINE";
const ENGINE_MB: &str = "mb";
const ENGINE_PION: &str = "pion";
/// How long `--version` capability probing of `stillfail-pion` may take.
const PROBE_VERSION_WITHIN: Duration = Duration::from_secs(3);
/// Cap on bytes read from `stillfail-pion --version`.
const PROBE_STDOUT_LIMIT: usize = 64 * 1024;
/// How long it may take to listen.
const LISTENS_WITHIN: Duration = Duration::from_secs(10);
/// How it hands Node the streams a connection's other end opens (its first line's `streams`; none said: 1). 2: each
/// with its index, so Node takes them in the order they were opened (a device's credential stream first, 2026-11-13).
/// 3: a route Node gave it (`route`) goes to the program that answers it, Node told the index went (station/mesh/served.ts);
/// 4: a route's segment `*` is any one; 5: meshConfigure, meshRemove, meshAttachLeaf and meshDetachLeaf (a front of 4
/// answered Node's mesh directory "no operation meshConfigure" on every try, 2026-11-18); 6: iroh.probeRelay (#7567),
/// unix backlog/retry and conn.hand skip (#7568), and noq path-idle/RTT-stall fixes (#7869/#7899/#7919), which a front
/// kept across updates otherwise never takes up (one of 5 ran a 40-hour-old binary, 2026-11-21); 7: noq-proto BBRv3
/// idle app_limited (#852) / startup pacing (#802) fixes and 4 MiB stream_receive_window (#8093); 8: BBRv3
/// loss_thresh(0.30) and gated lower-bound adaptation to prevent cross-border 10–25% loss collapse to min_pipe_cwnd.
/// A front kept from before a raise here is replaced once by the launcher that takes it up (`current`): the one thing
/// that does not come with an update, as it is kept across them.
pub const STREAMS: u64 = 8;

/// Metadata stamp of a Pion binary that failed probing or startup, so subsequent `SIGUSR2`/`renew` handovers keep
/// the healthy fallback MB front until the Pion binary actually changes on disk or config switches away and back.
#[derive(Clone, Debug, PartialEq, Eq)]
struct PionStamp {
    path: PathBuf,
    dev: u64,
    ino: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
    size: u64,
    mode: u32,
}

impl PionStamp {
    fn of(path: &Path) -> Option<PionStamp> {
        let meta = std::fs::metadata(path).ok()?;
        if !meta.is_file() {
            return None;
        }
        Some(PionStamp {
            path: path.to_path_buf(),
            dev: meta.dev(),
            ino: meta.ino(),
            mtime_sec: meta.mtime(),
            mtime_nsec: meta.mtime_nsec(),
            size: meta.len(),
            mode: meta.mode(),
        })
    }

    fn to_json(&self) -> Option<Value> {
        let path = self.path.to_str()?;
        Some(json!({
            "path": path,
            "dev": self.dev,
            "ino": self.ino,
            "mtimeSec": self.mtime_sec,
            "mtimeNsec": self.mtime_nsec,
            "size": self.size,
            "mode": self.mode,
        }))
    }

    fn from_json(v: &Value) -> Option<PionStamp> {
        Some(PionStamp {
            path: PathBuf::from(v["path"].as_str()?),
            dev: v["dev"].as_u64()?,
            ino: v["ino"].as_u64()?,
            mtime_sec: v["mtimeSec"].as_i64()?,
            mtime_nsec: v["mtimeNsec"].as_i64()?,
            size: v["size"].as_u64()?,
            mode: v["mode"].as_u64().and_then(|m| u32::try_from(m).ok())?,
        })
    }
}

/// A resolved front binary ready to launch (carries already-probed Pion metadata to avoid duplicate `--version` probes).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedProgram {
    pub engine: String,
    program: PathBuf,
    requested: String,
    fallback_pion_stamp: Option<PionStamp>,
}

/// Outcome of `Front::current()` during launcher `renew` / `resume()`.
pub enum CurrentFront {
    /// Kept running unchanged.
    Kept(Front),
    /// Ended the old front; caller should start this already-resolved replacement without re-probing `--version`.
    SwitchTo(ResolvedProgram),
    /// Ended the old front (streams upgrade, launcher identity change, or `EndForDirectBind`).
    Ended,
}

/// Decision for a running front at a `SIGUSR2` handover or launcher `renew`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrontDecision {
    /// Keep the currently running front untouched.
    Keep,
    /// End the running front and start this already-resolved target program.
    SwitchTo(ResolvedProgram),
    /// End the running front and leave no front running so the next Node binds the endpoint directly.
    EndForDirectBind,
}

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
    /// Which engine actually runs this front (`"mb"` or `"pion"`).
    engine: String,
    /// Which engine was requested when this front was started or last evaluated (`"mb"` or `"pion"`).
    requested: String,
    /// Stamp of the Pion binary when `requested == "pion"` fell back to `engine == "mb"`.
    fallback_pion_stamp: Option<PionStamp>,
    /// The launcher's executable identity when this front was started. macOS records it on the front's sockets.
    #[cfg(target_os = "macos")]
    launcher_uuid: Option<String>,
    /// A front from before this identity was recorded must be replaced once.
    #[cfg(target_os = "macos")]
    uuid_recorded: bool,
}

impl Front {
    pub fn engine(&self) -> &str {
        &self.engine
    }

    /// Evaluates whether this running front should be kept, switched to another engine, or ended for direct bind.
    /// When currently running `"mb"` and config/env requests `"pion"`, probes Pion BEFORE deciding to switch so a
    /// failing probe never kills a healthy MB front; remembers the failed Pion binary stamp to avoid restart loops.
    pub fn decide_transition(&mut self, app: &Path, data: &Path) -> FrontDecision {
        let config_mesh = read_config_mesh(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        self.decide_transition_with(
            app,
            config_mesh.as_ref(),
            mesh_env.as_deref(),
            global_env.as_deref(),
            mb_var.as_deref(),
            pion_var.as_deref(),
            true,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn decide_transition_with(
        &mut self,
        app: &Path,
        config_mesh: Option<&Value>,
        mesh_env: Option<&OsStr>,
        global_env: Option<&OsStr>,
        mb_var: Option<&OsStr>,
        pion_var: Option<&OsStr>,
        warn: bool,
    ) -> FrontDecision {
        let requested = select_requested_engine(mesh_env, config_mesh, global_env, warn);
        if requested == ENGINE_MB {
            if self.engine == ENGINE_MB {
                self.requested = ENGINE_MB.to_string();
                self.fallback_pion_stamp = None;
                return FrontDecision::Keep;
            }
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                return FrontDecision::SwitchTo(ResolvedProgram {
                    engine: ENGINE_MB.to_string(),
                    program: mb_program,
                    requested: ENGINE_MB.to_string(),
                    fallback_pion_stamp: None,
                });
            }
            return FrontDecision::EndForDirectBind;
        }
        // requested == ENGINE_PION
        let pion_path = pion_candidate_with(app, pion_var);
        if self.engine == ENGINE_PION {
            if is_executable_file(&pion_path) {
                self.requested = ENGINE_PION.to_string();
                self.fallback_pion_stamp = None;
                return FrontDecision::Keep;
            }
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                return FrontDecision::SwitchTo(ResolvedProgram {
                    engine: ENGINE_MB.to_string(),
                    program: mb_program,
                    requested: ENGINE_PION.to_string(),
                    fallback_pion_stamp: PionStamp::of(&pion_path),
                });
            }
            return FrontDecision::EndForDirectBind;
        }
        // Running MB while policy requests Pion.
        let current_stamp = PionStamp::of(&pion_path);
        if self.requested == ENGINE_PION && self.fallback_pion_stamp.is_some() && self.fallback_pion_stamp == current_stamp {
            // Same Pion binary we already fell back from: keep healthy MB front without probing or restarting.
            return FrontDecision::Keep;
        }
        if !is_executable_file(&pion_path) {
            if warn {
                log::warn(&format!("front mesh requested \"pion\" but {} is missing or not executable; keeping running \"mb\" front", pion_path.display()));
            }
            self.requested = ENGINE_PION.to_string();
            self.fallback_pion_stamp = current_stamp;
            return FrontDecision::Keep;
        }
        match probe_pion_mesh_support(&pion_path, PROBE_VERSION_WITHIN) {
            Ok(()) => FrontDecision::SwitchTo(ResolvedProgram {
                engine: ENGINE_PION.to_string(),
                program: pion_path,
                requested: ENGINE_PION.to_string(),
                fallback_pion_stamp: None,
            }),
            Err(ProbeError::TimedOut(reason)) => {
                // Transient timeout: keep healthy MB front without locking `fallback_pion_stamp` so the next handover can retry.
                if warn {
                    log::warn(&format!("front mesh requested \"pion\" but {} capability probe timed out ({reason}); keeping running \"mb\" front", pion_path.display()));
                }
                FrontDecision::Keep
            }
            Err(ProbeError::Deterministic(reason)) => {
                if warn {
                    log::warn(&format!("front mesh requested \"pion\" but {} failed capability probe ({reason}); keeping running \"mb\" front", pion_path.display()));
                }
                self.requested = ENGINE_PION.to_string();
                self.fallback_pion_stamp = current_stamp;
                FrontDecision::Keep
            }
        }
    }

    /// Whether the release at `app` has any front program on disk (file existence only, no `--version` probe).
    pub fn in_release(app: &Path, _data: &Path) -> bool {
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        mb_program_with(app, mb_var.as_deref()).is_some()
            || is_executable_file(&pion_candidate_with(app, pion_var.as_deref()))
    }

    /// Whether a binary exists on disk for the currently requested engine (or MB fallback for Pion), without probing.
    pub fn requested_program_available(app: &Path, data: &Path) -> bool {
        let config_mesh = read_config_mesh(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        let requested = select_requested_engine(mesh_env.as_deref(), config_mesh.as_ref(), global_env.as_deref(), false);
        if requested == ENGINE_PION && is_executable_file(&pion_candidate_with(app, pion_var.as_deref())) {
            return true;
        }
        mb_program_with(app, mb_var.as_deref()).is_some()
    }

    /// The front for the station of `data`, listening; none where the release has none or it did not start (said).
    /// If Pion passed its `--version` probe but subsequently fails to spawn or listen, falls back once to MoonBit
    /// and records `requested = "pion"` + the failed Pion binary's stamp so later handovers do not thrash.
    pub fn start(app: &Path, data: &Path) -> Option<Front> {
        // None of this launcher's runs (it starts one only where it has none): any other of this data directory is left
        // from before (a launcher killed, one from before front.pid) and holds the station's key on the relays.
        clean_orphans(data, None);
        let config_mesh = read_config_mesh(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        let resolved = resolve_program_full(
            app,
            config_mesh.as_ref(),
            mesh_env.as_deref(),
            global_env.as_deref(),
            mb_var.as_deref(),
            pion_var.as_deref(),
            true,
        )?;
        Self::start_resolved_with(resolved, app, mb_var.as_deref(), data)
    }

    /// Starts an already-resolved front program without re-running `--version` probing (used by `SIGUSR2` switching
    /// after `decide_transition` already probed Pion). Falls back once to MoonBit if Pion fails to spawn or listen.
    pub fn start_resolved(resolved: ResolvedProgram, app: &Path, data: &Path) -> Option<Front> {
        clean_orphans(data, None);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        Self::start_resolved_with(resolved, app, mb_var.as_deref(), data)
    }

    fn start_resolved_with(resolved: ResolvedProgram, app: &Path, mb_var: Option<&OsStr>, data: &Path) -> Option<Front> {
        if let Some(front) = spawn_front(&resolved.program, &resolved.engine, &resolved.requested, resolved.fallback_pion_stamp.clone(), data) {
            return Some(front);
        }
        if resolved.engine == ENGINE_PION {
            let stamp = PionStamp::of(&resolved.program);
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                log::warn(&format!("the front (engine pion, {}) failed to start or listen; falling back to \"mb\" ({})", resolved.program.display(), mb_program.display()));
                return spawn_front(&mb_program, ENGINE_MB, ENGINE_PION, stamp, data);
            }
        }
        None
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
        let mut state = json!({
            "pid": self.pid,
            "input": self.input.as_raw_fd(),
            "socket": self.socket,
            "streams": self.streams,
            "engine": self.engine,
            "requested": self.requested,
        });
        if let Some(stamp) = self.fallback_pion_stamp.as_ref().and_then(PionStamp::to_json) {
            state["fallbackPionStamp"] = stamp;
        }
        #[cfg(target_os = "macos")]
        {
            state["launcherUuid"] = json!(self.launcher_uuid);
        }
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
        let engine = state["engine"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| infer_engine_from_args(args_of(pid).as_deref()).to_string());
        let requested = state["requested"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| engine.clone());
        let fallback_pion_stamp = state.get("fallbackPionStamp").and_then(PionStamp::from_json);
        Some(Front {
            pid, input: unsafe { OwnedFd::from_raw_fd(input) }, socket, pid_file, started: None,
            streams: state["streams"].as_u64().unwrap_or(1),
            engine,
            requested,
            fallback_pion_stamp,
            #[cfg(target_os = "macos")]
            launcher_uuid: state["launcherUuid"].as_str().map(str::to_string),
            #[cfg(target_os = "macos")]
            uuid_recorded: state.get("launcherUuid").is_some(),
        })
    }

    /// Itself where it hands streams as this launcher's release does and matches the desired engine; else ended (its
    /// connections go with it, the devices dial again), so that one of the release / desired engine starts in its place.
    pub fn current(self, app: &Path, data: &Path) -> CurrentFront {
        let config_mesh = read_config_mesh(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        self.current_with(
            app,
            config_mesh.as_ref(),
            mesh_env.as_deref(),
            global_env.as_deref(),
            mb_var.as_deref(),
            pion_var.as_deref(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn current_with(
        self,
        app: &Path,
        config_mesh: Option<&Value>,
        mesh_env: Option<&OsStr>,
        global_env: Option<&OsStr>,
        mb_var: Option<&OsStr>,
        pion_var: Option<&OsStr>,
    ) -> CurrentFront {
        #[cfg(target_os = "macos")]
        let identity_changed = identity_needs_refresh(self.uuid_recorded, self.launcher_uuid.as_deref(), executable_uuid().as_deref());
        #[cfg(not(target_os = "macos"))]
        let identity_changed = false;
        self.current_with_identity(app, config_mesh, mesh_env, global_env, mb_var, pion_var, identity_changed)
    }

    #[allow(clippy::too_many_arguments)]
    fn current_with_identity(
        mut self,
        app: &Path,
        config_mesh: Option<&Value>,
        mesh_env: Option<&OsStr>,
        global_env: Option<&OsStr>,
        mb_var: Option<&OsStr>,
        pion_var: Option<&OsStr>,
        identity_changed: bool,
    ) -> CurrentFront {
        if identity_changed {
            log::warn(&format!("the front (pid {}) was started by another launcher identity: ending it so macOS can match its local network permission", self.pid));
        } else if self.streams < STREAMS {
            log::warn(&format!("the front (pid {}) hands streams as {} and this release as {STREAMS}: ending it for the release's", self.pid, self.streams));
        } else {
            return match self.decide_transition_with(app, config_mesh, mesh_env, global_env, mb_var, pion_var, true) {
                FrontDecision::Keep => CurrentFront::Kept(self),
                FrontDecision::SwitchTo(resolved) => {
                    log::warn(&format!("the front (pid {}) runs engine {} and desired engine is {}: ending it to switch", self.pid, self.engine, resolved.engine));
                    self.end();
                    CurrentFront::SwitchTo(resolved)
                }
                FrontDecision::EndForDirectBind => {
                    log::warn(&format!("the front (pid {}) engine ({}) disabled with no fallback binary: ending it for direct bind", self.pid, self.engine));
                    self.end();
                    CurrentFront::Ended
                }
            };
        }
        // SAFETY: a signal to this process's child (a launcher before this one started it in this same process), then
        // its exit waited for, so the next binds its socket and the station's endpoint with it gone.
        unsafe {
            libc::kill(self.pid, libc::SIGKILL);
            libc::waitpid(self.pid, std::ptr::null_mut(), 0);
        }
        forget_pid(&self.pid_file, self.pid);
        CurrentFront::Ended
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

fn spawn_front(
    program: &Path,
    engine: &str,
    requested: &str,
    fallback_pion_stamp: Option<PionStamp>,
    data: &Path,
) -> Option<Front> {
    let run = data.join("run");
    let socket = run.join("front.sock");
    let pid_file = run.join(PID_FILE);
    let mut command = Command::new(program);
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
            log::warn(&format!("the front (engine {engine}, {}) did not start: {error}; each Node binds the station's endpoint itself", program.display()));
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
            log::info(&format!("the front listens (pid {pid}, engine {engine}, {}): {}", program.display(), socket.display()));
            Some(Front {
                pid, input, socket, pid_file, started: Some(Instant::now()), streams,
                engine: engine.to_string(),
                requested: requested.to_string(),
                fallback_pion_stamp,
                #[cfg(target_os = "macos")]
                launcher_uuid: executable_uuid(),
                #[cfg(target_os = "macos")]
                uuid_recorded: true,
            })
        }
        other => {
            log::warn(&format!("the front (pid {pid}, engine {engine}) did not listen ({other:?}); each Node binds the station's endpoint itself"));
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

/// Infers engine from a live front process's `argv[0]` when resuming from an older launcher state that omitted `engine`.
fn infer_engine_from_args(args: Option<&[std::ffi::OsString]>) -> &'static str {
    let Some(first) = args.and_then(|list| list.first()) else {
        return ENGINE_MB;
    };
    match Path::new(first).file_name().and_then(|n| n.to_str()) {
        Some(name) if name == "stillfail-pion" => ENGINE_PION,
        _ => ENGINE_MB,
    }
}

/// ECMAScript `String.prototype.trim()` whitespace (includes U+FEFF BOM, excludes U+0085 NEL) for 1:1 parity with TS.
fn is_es_whitespace(c: char) -> bool {
    matches!(
        c,
        '\u{0009}'..='\u{000D}'
            | '\u{0020}'
            | '\u{00A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

fn trim_es_whitespace(s: &str) -> &str {
    s.trim_matches(is_es_whitespace)
}

fn read_config_mesh(data: &Path) -> Option<Value> {
    let path = crate::data::var("CONFIG").map(PathBuf::from).unwrap_or_else(|| data.join("config.json"));
    read_config_mesh_at(&path)
}

fn read_config_mesh_at(path: &Path) -> Option<Value> {
    let bytes = std::fs::read(path).ok()?;
    let raw: Value = serde_json::from_slice(&bytes).ok()?;
    let readers = raw.get("readers")?.as_object()?;
    readers.get("mesh").cloned()
}

fn parse_engine_str(raw: &str, source: &str, warn: bool) -> &'static str {
    match trim_es_whitespace(raw).to_ascii_lowercase().as_str() {
        ENGINE_MB => ENGINE_MB,
        ENGINE_PION => ENGINE_PION,
        "shadow" => {
            if warn {
                log::warn(&format!("front mesh engine {raw:?} from {source} forbids shadow execution; falling back to \"mb\""));
            }
            ENGINE_MB
        }
        _ => {
            if warn {
                log::warn(&format!("invalid front mesh engine {raw:?} from {source}; expected \"mb\" | \"pion\", falling back to \"mb\""));
            }
            ENGINE_MB
        }
    }
}

/// Parses an environment variable value for engine selection: `None` if unset/blank; `Some(engine)` otherwise.
/// Non-UTF-8 non-empty values fail safe to `"mb"` (do not fall through to config/global env).
fn parse_engine_env(raw: Option<&OsStr>, source: &str, warn: bool) -> Option<&'static str> {
    let os = raw?;
    if os.is_empty() {
        return None;
    }
    match os.to_str() {
        Some(s) if trim_es_whitespace(s).is_empty() => None,
        Some(s) => Some(parse_engine_str(s, source, warn)),
        None => {
            if warn {
                log::warn(&format!("non-UTF-8 front mesh engine in {source}; falling back to \"mb\""));
            }
            Some(ENGINE_MB)
        }
    }
}

/// Resolves the requested engine for `--builder mesh` matching `station/src/read/reader-select.ts`:
/// `STILLFAIL_READER_MESH > config.json readers.mesh > STILLFAIL_READER_ENGINE > "mb"`.
fn select_requested_engine(
    mesh_env: Option<&OsStr>,
    config_mesh: Option<&Value>,
    global_env: Option<&OsStr>,
    warn: bool,
) -> &'static str {
    if let Some(engine) = parse_engine_env(mesh_env, MESH_ENGINE_VAR, warn) {
        return engine;
    }
    if let Some(val) = config_mesh {
        match val {
            Value::Null => {}
            Value::String(s) if trim_es_whitespace(s).is_empty() => {}
            Value::String(s) => return parse_engine_str(s, "config.json readers.mesh", warn),
            other => {
                if warn {
                    log::warn(&format!("invalid front mesh engine {other} from config.json readers.mesh; expected \"mb\" | \"pion\", falling back to \"mb\""));
                }
                return ENGINE_MB;
            }
        }
    }
    if let Some(engine) = parse_engine_env(global_env, GLOBAL_ENGINE_VAR, warn) {
        return engine;
    }
    ENGINE_MB
}

/// Resolves an explicit binary override env var to an absolute path so `access(X_OK)` and `Command::new` always refer
/// to the exact same file (never falling back to `PATH` lookup on single-segment relative names).
fn resolve_override_path(raw: Option<&OsStr>) -> Option<PathBuf> {
    let os = raw?;
    if os.is_empty() {
        return None;
    }
    let path = match os.to_str() {
        Some(s) => {
            let trimmed = trim_es_whitespace(s);
            if trimmed.is_empty() {
                return None;
            }
            PathBuf::from(trimmed)
        }
        None => PathBuf::from(os),
    };
    if path.is_absolute() {
        Some(path)
    } else {
        std::env::current_dir().ok().map(|cwd| cwd.join(&path)).or(Some(path))
    }
}

fn mb_program_with(app: &Path, mb_var: Option<&OsStr>) -> Option<PathBuf> {
    if let Some(given) = mb_var.filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(given));
    }
    let program = app.join(PROGRAM_IN_APP);
    program.is_file().then_some(program)
}

fn pion_candidate_with(app: &Path, pion_var: Option<&OsStr>) -> PathBuf {
    if let Some(given) = resolve_override_path(pion_var) {
        return given;
    }
    app.join(PION_PROGRAM_IN_APP)
}

fn is_executable_file(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    let Ok(cpath) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: NUL-terminated path passed to POSIX access(2).
    unsafe { libc::access(cpath.as_ptr(), libc::X_OK) == 0 }
}

/// Matches the first `(?:^|\s)modes:([a-z0-9_,-]+)(?=\s|$)` using ECMAScript whitespace (1:1 with `mb-reader.ts`
/// `parsePionVersionModes`) and requires `mesh` as an exact comma-separated entry (rejects `mesh2`, `mesh.v2`, etc.).
fn version_supports_mesh(stdout: &str) -> bool {
    let mut prev_is_ws = true;
    for (idx, ch) in stdout.char_indices() {
        if prev_is_ws {
            let rest = &stdout[idx..];
            if rest.len() >= 6 && rest.as_bytes()[..6].eq_ignore_ascii_case(b"modes:") {
                let after = &rest[6..];
                let token_end = after.find(is_es_whitespace).unwrap_or(after.len());
                let csv = &after[..token_end];
                if !csv.is_empty()
                    && csv
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b',' | b'-'))
                {
                    return csv.split(',').any(|m| m.eq_ignore_ascii_case("mesh"));
                }
            }
        }
        prev_is_ws = is_es_whitespace(ch);
    }
    false
}

#[derive(Debug)]
enum ProbeError {
    TimedOut(String),
    Deterministic(String),
}

/// Runs `<program> --version` with a bounded timeout so a broken or wedged binary can never block launcher startup.
fn probe_pion_mesh_support(program: &Path, within: Duration) -> std::result::Result<(), ProbeError> {
    let mut child = Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| ProbeError::Deterministic(format!("spawn failed: {e}")))?;
    let Some(mut out) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ProbeError::Deterministic("missing stdout pipe".to_string()));
    };
    let deadline = Instant::now() + within;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    let mut timed_out = false;
    let mut overflowed = false;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            timed_out = true;
            break;
        }
        let mut pfd = libc::pollfd { fd: out.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: poll on one live pollfd.
        let polled = unsafe { libc::poll(&mut pfd, 1, left.as_millis().min(i32::MAX as u128) as libc::c_int) };
        if polled < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if polled <= 0 {
            timed_out = true;
            break;
        }
        match out.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if buf.len() + n > PROBE_STDOUT_LIMIT {
                    overflowed = true;
                    break;
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                drop(out);
                let _ = child.kill();
                let _ = child.wait();
                return Err(ProbeError::Deterministic(format!("read failed: {e}")));
            }
        }
    }
    drop(out);
    if overflowed {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ProbeError::Deterministic(format!("--version output exceeded {PROBE_STDOUT_LIMIT} bytes")));
    }
    if timed_out {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ProbeError::TimedOut(format!("--version timed out after {} ms", within.as_millis())));
    }
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ProbeError::TimedOut(format!("--version did not exit within {} ms", within.as_millis())));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ProbeError::Deterministic(format!("wait failed: {e}")));
            }
        }
    };
    if !status.success() {
        return Err(ProbeError::Deterministic(format!("--version exited with {status}")));
    }
    let text = String::from_utf8_lossy(&buf);
    if !version_supports_mesh(&text) {
        return Err(ProbeError::Deterministic(format!("--version modes list does not include mesh ({})", text.trim())));
    }
    Ok(())
}

fn resolve_program_full(
    app: &Path,
    config_mesh: Option<&Value>,
    mesh_env: Option<&OsStr>,
    global_env: Option<&OsStr>,
    mb_var: Option<&OsStr>,
    pion_var: Option<&OsStr>,
    warn: bool,
) -> Option<ResolvedProgram> {
    let requested = select_requested_engine(mesh_env, config_mesh, global_env, warn);
    let mut fallback_pion_stamp = None;
    if requested == ENGINE_PION {
        let pion_path = pion_candidate_with(app, pion_var);
        if !is_executable_file(&pion_path) {
            fallback_pion_stamp = PionStamp::of(&pion_path);
            if warn {
                log::warn(&format!("front mesh requested \"pion\" but {} is missing or not executable; falling back to \"mb\"", pion_path.display()));
            }
        } else {
            match probe_pion_mesh_support(&pion_path, PROBE_VERSION_WITHIN) {
                Ok(()) => {
                    return Some(ResolvedProgram {
                        engine: ENGINE_PION.to_string(),
                        program: pion_path,
                        requested: ENGINE_PION.to_string(),
                        fallback_pion_stamp: None,
                    });
                }
                Err(ProbeError::TimedOut(reason)) => {
                    // Transient timeout: fall back to MB for now without locking `fallback_pion_stamp`.
                    if warn {
                        log::warn(&format!("front mesh requested \"pion\" but {} capability probe timed out ({reason}); falling back to \"mb\"", pion_path.display()));
                    }
                }
                Err(ProbeError::Deterministic(reason)) => {
                    fallback_pion_stamp = PionStamp::of(&pion_path);
                    if warn {
                        log::warn(&format!("front mesh requested \"pion\" but {} failed capability probe ({reason}); falling back to \"mb\"", pion_path.display()));
                    }
                }
            }
        }
    }
    mb_program_with(app, mb_var).map(|program| ResolvedProgram {
        engine: ENGINE_MB.to_string(),
        program,
        requested: if fallback_pion_stamp.is_some() { ENGINE_PION.to_string() } else { ENGINE_MB.to_string() },
        fallback_pion_stamp,
    })
}

#[cfg(test)]
fn resolve_program_with(
    app: &Path,
    config_mesh: Option<&Value>,
    mesh_env: Option<&OsStr>,
    global_env: Option<&OsStr>,
    mb_var: Option<&OsStr>,
    pion_var: Option<&OsStr>,
    warn: bool,
) -> Option<(String, PathBuf)> {
    resolve_program_full(app, config_mesh, mesh_env, global_env, mb_var, pion_var, warn)
        .map(|r| (r.engine, r.program))
}

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

#[cfg(test)]
mod engine_tests {
    use super::{
        CurrentFront, ENGINE_MB, ENGINE_PION, Front, FrontDecision, PROBE_STDOUT_LIMIT, PionStamp,
        ProbeError, STREAMS, infer_engine_from_args, mb_program_with, probe_pion_mesh_support,
        read_config_mesh_at, resolve_override_path, resolve_program_with, select_requested_engine,
        version_supports_mesh,
    };
    use serde_json::json;
    use std::ffi::{OsStr, OsString};
    use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    static SEQ: AtomicU64 = AtomicU64::new(0);
    static EXEC_LOCK: Mutex<()> = Mutex::new(());

    fn temp_dir(tag: &str) -> PathBuf {
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("front-engine-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_script(path: &Path, body: &str, executable: bool) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        let tmp = path.with_extension(format!("tmp-{}", SEQ.fetch_add(1, Ordering::Relaxed)));
        std::fs::write(&tmp, body).unwrap();
        let mode = if executable { 0o755 } else { 0o644 };
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode)).unwrap();
        std::fs::rename(&tmp, path).unwrap();
    }

    fn os(s: &str) -> Option<&OsStr> {
        Some(OsStr::new(s))
    }

    #[test]
    fn precedence_matches_reader_select_ts() {
        let cfg_pion = json!("pion");
        let cfg_mb = json!("mb");
        let cfg_blank = json!("   ");

        // Default is mb.
        assert_eq!(select_requested_engine(None, None, None, false), ENGINE_MB);
        // Global env selects pion when neither per-mode env nor config sets it.
        assert_eq!(select_requested_engine(None, None, os("pion"), false), ENGINE_PION);
        // config.json readers.mesh overrides STILLFAIL_READER_ENGINE.
        assert_eq!(select_requested_engine(None, Some(&cfg_mb), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(None, Some(&cfg_pion), os("mb"), false), ENGINE_PION);
        // Blank config falls through to global env.
        assert_eq!(select_requested_engine(None, Some(&cfg_blank), os("pion"), false), ENGINE_PION);
        // STILLFAIL_READER_MESH overrides both config and global env.
        assert_eq!(select_requested_engine(os("mb"), Some(&cfg_pion), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(os("  PiOn \n"), Some(&cfg_mb), os("mb"), false), ENGINE_PION);
        // Blank STILLFAIL_READER_MESH falls through to config.
        assert_eq!(select_requested_engine(os("  \t "), Some(&cfg_pion), os("mb"), false), ENGINE_PION);
    }

    #[test]
    fn invalid_shadow_non_utf8_and_ecmascript_whitespace_match_ts() {
        let cfg_pion = json!("pion");
        let cfg_shadow = json!("shadow");
        let cfg_num = json!(42);
        let cfg_bad = json!("rust");

        // Shadow is strictly forbidden for mesh (network mode).
        assert_eq!(select_requested_engine(os("shadow"), Some(&cfg_pion), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(os(" SHADOW "), None, None, false), ENGINE_MB);
        assert_eq!(select_requested_engine(None, Some(&cfg_shadow), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(None, None, os("shadow"), false), ENGINE_MB);

        // Invalid env must fail safe to mb without falling through to config=pion.
        assert_eq!(select_requested_engine(os("typo"), Some(&cfg_pion), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(None, Some(&cfg_num), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(None, Some(&cfg_bad), os("pion"), false), ENGINE_MB);

        // Non-UTF-8 env var is treated as non-empty invalid value -> falls back to mb without falling through.
        let non_utf8 = OsStr::from_bytes(b"\xff\xfe");
        assert_eq!(select_requested_engine(Some(non_utf8), Some(&cfg_pion), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(None, None, Some(non_utf8), false), ENGINE_MB);

        // ECMAScript trim: U+FEFF (BOM) IS trimmed; U+0085 (NEL) is NOT trimmed (invalid -> mb).
        assert_eq!(select_requested_engine(os("\u{FEFF}pion\u{FEFF}"), None, None, false), ENGINE_PION);
        assert_eq!(select_requested_engine(os("\u{0085}pion"), Some(&cfg_pion), os("pion"), false), ENGINE_MB);
        assert_eq!(select_requested_engine(os("\u{FEFF}"), Some(&cfg_pion), None, false), ENGINE_PION);

        // Non-object `readers` in config.json is safely ignored.
        let dir = temp_dir("bad-readers");
        for body in [r#"{"readers":["pion"]}"#, r#"{"readers":"pion"}"#, r#"{"readers":null}"#] {
            let cfg_path = dir.join("config.json");
            std::fs::write(&cfg_path, body).unwrap();
            assert_eq!(read_config_mesh_at(&cfg_path), None);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn version_supports_mesh_uses_first_match_and_exact_csv_boundaries() {
        assert!(version_supports_mesh("stillfail-pion 0.3.0 modes:footprint,forward,mesh"));
        assert!(version_supports_mesh("stillfail-pion 0.3.0 modes:mesh"));
        assert!(version_supports_mesh("stillfail-pion 0.3.0 modes:footprint,mesh,serve\n"));
        // ECMAScript whitespace prefixes (U+00A0 NBSP, U+000B VT) are accepted.
        assert!(version_supports_mesh("stillfail-pion 0.3.0\u{00A0}modes:mesh"));
        assert!(version_supports_mesh("stillfail-pion 0.3.0\u{000B}modes:mesh"));
        // Non-whitespace suffix (e.g. `.v2`) is rejected rather than truncated to `mesh`.
        assert!(!version_supports_mesh("stillfail-pion 0.3.0 modes:mesh.v2"));
        assert!(!version_supports_mesh("stillfail-pion 0.3.0 modes:footprint,mesh2"));
        assert!(!version_supports_mesh("stillfail-pion 0.3.0 modes:footprint,submesh"));
        assert!(!version_supports_mesh("stillfail-pion 0.3.0 xmodes:mesh"));
        assert!(!version_supports_mesh("stillfail-pion 0.3.0"));
        // Only the FIRST valid modes: token is consulted (matches TS regex `.exec`).
        assert!(!version_supports_mesh("stillfail-pion 0.3.0 modes:footprint,mesh2 modes:mesh"));
    }

    #[test]
    fn probe_handles_timeout_oversized_truncation_and_nonzero_exit() {
        let _exec = EXEC_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("probe-edge");

        // 1. 200ms timeout kills slow binary cleanly and classifies as ProbeError::TimedOut (transient, never locks stamp).
        let slow = dir.join("pion-slow");
        write_script(&slow, "#!/bin/sh\nsleep 5\n", true);
        match probe_pion_mesh_support(&slow, Duration::from_millis(200)) {
            Err(ProbeError::TimedOut(msg)) => assert!(msg.contains("timed out"), "{msg}"),
            other => panic!("expected ProbeError::TimedOut, got {other:?}"),
        }

        // 2. Output exceeding 64 KiB right across `modes:mesh2` boundary must fail deterministically (never truncate to `mesh`).
        let big = dir.join("pion-big");
        let pad_len = PROBE_STDOUT_LIMIT - "modes:mesh".len();
        write_script(
            &big,
            &format!("#!/bin/sh\nawk 'BEGIN{{for(i=0;i<{pad_len};i++) printf \" \"; printf \"modes:mesh2\\n\"}}'\n"),
            true,
        );
        match probe_pion_mesh_support(&big, Duration::from_secs(3)) {
            Err(ProbeError::Deterministic(msg)) => assert!(msg.contains("exceeded"), "{msg}"),
            other => panic!("expected ProbeError::Deterministic(exceeded), got {other:?}"),
        }

        // 3. Valid modes:mesh output but exit 1 must fail deterministically.
        let exit1 = dir.join("pion-exit1");
        write_script(&exit1, "#!/bin/sh\necho 'stillfail-pion 0.3.0 modes:mesh'\nexit 1\n", true);
        match probe_pion_mesh_support(&exit1, Duration::from_secs(3)) {
            Err(ProbeError::Deterministic(msg)) => assert!(msg.contains("exited"), "{msg}"),
            other => panic!("expected ProbeError::Deterministic(exited), got {other:?}"),
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relative_pion_override_resolves_to_cwd_while_mb_keeps_path_lookup() {
        let resolved = resolve_override_path(os("stillfail-pion")).expect("resolved");
        assert!(resolved.is_absolute(), "pion override must be absolute: {}", resolved.display());
        assert_eq!(resolved.file_name().and_then(|n| n.to_str()), Some("stillfail-pion"));
        assert_eq!(resolve_override_path(os("  \u{FEFF} ")), None);

        // STILLFAIL_MB_READER keeps single-segment command names intact for PATH lookup.
        let mb = mb_program_with(Path::new("/nonexistent-app"), os("custom-mb-reader")).expect("mb");
        assert_eq!(mb, PathBuf::from("custom-mb-reader"));
    }

    #[test]
    fn pion_resolution_selects_valid_binary_and_falls_back_when_missing_or_unsupported() {
        let _exec = EXEC_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("resolve");
        let app = dir.join("app");
        let mb_bin = app.join("station/stillfail-reader");
        write_script(&mb_bin, "#!/bin/sh\necho mb\n", true);

        // 1. Valid Pion binary advertising modes:...,mesh,... is selected.
        let good_pion = dir.join("pion-good");
        write_script(&good_pion, "#!/bin/sh\necho 'stillfail-pion 0.3.0 modes:footprint,forward,mesh'\n", true);
        let resolved = resolve_program_with(&app, None, os("pion"), None, None, Some(good_pion.as_os_str()), false);
        assert_eq!(resolved, Some((ENGINE_PION.to_string(), good_pion.clone())));

        // 2. Default (mb) selects stillfail-reader even when good Pion binary exists.
        let resolved_mb = resolve_program_with(&app, None, None, None, None, Some(good_pion.as_os_str()), false);
        assert_eq!(resolved_mb, Some((ENGINE_MB.to_string(), mb_bin.clone())));

        // 3. Missing Pion binary falls back safely to mb.
        let missing_pion = dir.join("pion-missing");
        let resolved_missing = resolve_program_with(&app, None, os("pion"), None, None, Some(missing_pion.as_os_str()), false);
        assert_eq!(resolved_missing, Some((ENGINE_MB.to_string(), mb_bin.clone())));

        // 4. Non-executable Pion file falls back safely to mb.
        let nonexec_pion = dir.join("pion-nonexec");
        write_script(&nonexec_pion, "#!/bin/sh\necho 'stillfail-pion 0.3.0 modes:mesh'\n", false);
        let resolved_nonexec = resolve_program_with(&app, None, os("pion"), None, None, Some(nonexec_pion.as_os_str()), false);
        assert_eq!(resolved_nonexec, Some((ENGINE_MB.to_string(), mb_bin.clone())));

        // 5. Pion binary whose --version lacks exact `mesh` (e.g. only `mesh2`) falls back safely to mb.
        let bad_modes_pion = dir.join("pion-mesh2");
        write_script(&bad_modes_pion, "#!/bin/sh\necho 'stillfail-pion 0.3.0 modes:footprint,mesh2'\n", true);
        let resolved_bad_modes = resolve_program_with(&app, None, os("pion"), None, None, Some(bad_modes_pion.as_os_str()), false);
        assert_eq!(resolved_bad_modes, Some((ENGINE_MB.to_string(), mb_bin.clone())));

        // 6. Pion binary whose --version exits non-zero falls back safely to mb.
        let fail_pion = dir.join("pion-fail");
        write_script(&fail_pion, "#!/bin/sh\nexit 1\n", true);
        let resolved_fail = resolve_program_with(&app, None, os("pion"), None, None, Some(fail_pion.as_os_str()), false);
        assert_eq!(resolved_fail, Some((ENGINE_MB.to_string(), mb_bin.clone())));

        // 7. Config file readers.mesh = "pion" resolves release's <app>/station/stillfail-pion when STILLFAIL_PION_READER is unset.
        let app_pion = app.join("station/stillfail-pion");
        write_script(&app_pion, "#!/bin/sh\necho 'stillfail-pion 0.3.0 modes:footprint,mesh'\n", true);
        let cfg_path = dir.join("config.json");
        std::fs::write(&cfg_path, r#"{"readers":{"mesh":"pion"}}"#).unwrap();
        let cfg_val = read_config_mesh_at(&cfg_path);
        let resolved_cfg = resolve_program_with(&app, cfg_val.as_ref(), None, None, None, Some(OsStr::new("  ")), false);
        assert_eq!(resolved_cfg, Some((ENGINE_PION.to_string(), app_pion)));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn state_and_resumed_round_trip_engine_requested_and_fallback_stamp() {
        let dir = temp_dir("state");
        let run = dir.join("run");
        std::fs::create_dir_all(&run).unwrap();
        let socket = run.join("front.sock");
        let pion_file = dir.join("stillfail-pion");
        std::fs::write(&pion_file, b"stub").unwrap();
        let stamp = PionStamp::of(&pion_file).expect("stamp");

        let make_pipe_fd = || -> i32 {
            let mut fds = [0; 2];
            assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
            unsafe { libc::close(fds[0]) };
            fds[1]
        };

        // Round-trip with engine = "mb", requested = "pion", fallback_pion_stamp = Some(stamp).
        let fd_fb = make_pipe_fd();
        let front = Front {
            pid: 4242,
            input: unsafe { OwnedFd::from_raw_fd(fd_fb) },
            socket: socket.clone(),
            pid_file: run.join("front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_PION.to_string(),
            fallback_pion_stamp: Some(stamp.clone()),
            #[cfg(target_os = "macos")]
            launcher_uuid: None,
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let serialized = front.state();
        assert_eq!(serialized["engine"], json!("mb"));
        assert_eq!(serialized["requested"], json!("pion"));
        let Front { input, .. } = front;
        let _leaked = input.into_raw_fd();
        let resumed = Front::resumed(&serialized).expect("resumed front");
        assert_eq!(resumed.engine(), ENGINE_MB);
        assert_eq!(resumed.requested, ENGINE_PION);
        assert_eq!(resumed.fallback_pion_stamp, Some(stamp));
        assert_eq!(resumed.pid, 4242);
        drop(resumed);

        // Old launcher state without "engine"/"requested" defaults safely to "mb".
        let fd_old = make_pipe_fd();
        let old_state = json!({
            "pid": 5151,
            "input": fd_old,
            "socket": socket,
            "streams": STREAMS,
        });
        let resumed_old = Front::resumed(&old_state).expect("resumed old front");
        assert_eq!(resumed_old.engine(), ENGINE_MB);
        assert_eq!(resumed_old.requested, ENGINE_MB);
        assert_eq!(resumed_old.fallback_pion_stamp, None);
        drop(resumed_old);

        // Legacy inference from argv[0] recognizes stillfail-pion.
        let pion_args = vec![OsString::from("/opt/stillfail/station/stillfail-pion"), OsString::from("--builder"), OsString::from("mesh")];
        let mb_args = vec![OsString::from("/opt/stillfail/station/stillfail-reader"), OsString::from("--builder"), OsString::from("mesh")];
        assert_eq!(infer_engine_from_args(Some(&pion_args)), ENGINE_PION);
        assert_eq!(infer_engine_from_args(Some(&mb_args)), ENGINE_MB);
        assert_eq!(infer_engine_from_args(None), ENGINE_MB);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn current_with_keeps_matching_and_ends_switched_or_direct_bind() {
        let _exec = EXEC_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("current");
        let app = dir.join("app");
        let data = dir.join("data");
        std::fs::create_dir_all(data.join("run")).unwrap();
        write_script(&app.join("station/stillfail-reader"), "#!/bin/sh\necho mb\n", true);
        write_script(&app.join("station/stillfail-pion"), "#!/bin/sh\necho 'stillfail-pion 0.1.0 modes:mesh'\n", true);
        let cfg_pion = json!("pion");
        let cfg_mb = json!("mb");

        let spawn_cat = || -> (i32, OwnedFd) {
            let mut child = Command::new("/bin/cat").stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap();
            let pid = child.id() as i32;
            let input = unsafe { OwnedFd::from_raw_fd(child.stdin.take().unwrap().into_raw_fd()) };
            drop(child);
            (pid, input)
        };

        // 1. Matching engine ("pion") is kept via hermetic `current_with` (no host env dependency).
        let (pid1, input1) = spawn_cat();
        let kept = Front {
            pid: pid1,
            input: input1,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_PION.to_string(),
            requested: ENGINE_PION.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let kept = match kept.current_with(&app, Some(&cfg_pion), None, None, None, None) {
            CurrentFront::Kept(f) => f,
            _ => panic!("matching engine front must be kept"),
        };
        assert_eq!(kept.pid, pid1);
        kept.end();

        // 2. Mismatched engine ("mb" while config wants "pion" with valid Pion binary) is cleanly ended and returns SwitchTo.
        let (pid2, input2) = spawn_cat();
        let old = Front {
            pid: pid2,
            input: input2,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_MB.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert!(matches!(
            old.current_with(&app, Some(&cfg_pion), None, None, None, None),
            CurrentFront::SwitchTo(ref r) if r.engine == ENGINE_PION
        ));
        assert_ne!(unsafe { libc::kill(pid2, 0) }, 0, "old front process must have exited");

        // 3. Running MB when Pion fails probe keeps the healthy MB front (never kills before probing!).
        let bad_pion = dir.join("bad-pion");
        write_script(&bad_pion, "#!/bin/sh\necho 'stillfail-pion 0.1.0 modes:mesh2'\n", true);
        let (pid3, input3) = spawn_cat();
        let mut healthy_mb = Front {
            pid: pid3,
            input: input3,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_MB.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            healthy_mb.decide_transition_with(&app, Some(&cfg_pion), None, None, None, Some(bad_pion.as_os_str()), false),
            FrontDecision::Keep
        );
        assert_eq!(healthy_mb.requested, ENGINE_PION);
        assert!(healthy_mb.fallback_pion_stamp.is_some());
        healthy_mb.end();

        // 4. Pion-only app rolled back to "mb" decides EndForDirectBind.
        let pion_only_app = dir.join("pion-only-app");
        write_script(&pion_only_app.join("station/stillfail-pion"), "#!/bin/sh\necho 'stillfail-pion 0.1.0 modes:mesh'\n", true);
        let (pid4, input4) = spawn_cat();
        let mut pion_only = Front {
            pid: pid4,
            input: input4,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_PION.to_string(),
            requested: ENGINE_PION.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            pion_only.decide_transition_with(&pion_only_app, Some(&cfg_mb), None, None, None, None, false),
            FrontDecision::EndForDirectBind
        );
        pion_only.end();

        // 5. `chmod +x` on a previously non-executable Pion binary changes `PionStamp.mode` without changing mtime/ino/size,
        //    so the next handover re-probes and switches to Pion.
        let chmod_pion = dir.join("chmod-pion");
        write_script(&chmod_pion, "#!/bin/sh\necho 'stillfail-pion 0.1.0 modes:mesh'\n", false);
        let stamp_before = PionStamp::of(&chmod_pion).expect("stamp before chmod");
        let (pid5, input5) = spawn_cat();
        let mut waiting_mb = Front {
            pid: pid5,
            input: input5,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_MB.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            waiting_mb.decide_transition_with(&app, Some(&cfg_pion), None, None, None, Some(chmod_pion.as_os_str()), false),
            FrontDecision::Keep
        );
        assert_eq!(waiting_mb.fallback_pion_stamp.as_ref(), Some(&stamp_before));
        std::fs::set_permissions(&chmod_pion, std::fs::Permissions::from_mode(0o755)).unwrap();
        let stamp_after = PionStamp::of(&chmod_pion).expect("stamp after chmod");
        assert_ne!(stamp_before.mode, stamp_after.mode);
        assert!(matches!(
            waiting_mb.decide_transition_with(&app, Some(&cfg_pion), None, None, None, Some(chmod_pion.as_os_str()), false),
            FrontDecision::SwitchTo(ref r) if r.engine == ENGINE_PION
        ));
        waiting_mb.end();

        // 6. Single `--version` probe on MB -> Pion switch via `current_with` (`resume()`) + `start_resolved_with`.
        let probe_count_file = dir.join("probe-count");
        let counting_pion = dir.join("counting-pion");
        write_script(
            &counting_pion,
            &format!(
                "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 1 >> '{}'\n  echo 'stillfail-pion 0.1.0 modes:mesh'\n  exit 0\nfi\nprintf '{{\"listening\":\"%s\",\"streams\":8}}\\n' \"$4\"\nexec cat > /dev/null\n",
                probe_count_file.display()
            ),
            true,
        );
        let (pid6, input6) = spawn_cat();
        let mb_switch = Front {
            pid: pid6,
            input: input6,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_MB.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let resolved = match mb_switch.current_with(&app, Some(&cfg_pion), None, None, None, Some(counting_pion.as_os_str())) {
            CurrentFront::SwitchTo(r) => r,
            _ => panic!("expected CurrentFront::SwitchTo"),
        };
        let started_pion = Front::start_resolved_with(resolved, &app, None, &data).expect("started pion");
        assert_eq!(started_pion.engine(), ENGINE_PION);
        started_pion.end();
        let probes = std::fs::read_to_string(&probe_count_file).unwrap().lines().count();
        assert_eq!(probes, 1, "MB -> Pion switch via resume/current_with must run --version exactly once");

        // 7. Non-UTF-8 `PionStamp.path` omits `fallbackPionStamp` cleanly in `Front::state()` without panicking.
        let non_utf8_stamp = PionStamp {
            path: PathBuf::from(OsStr::from_bytes(b"/tmp/\xff/stillfail-pion")),
            dev: 1,
            ino: 2,
            mtime_sec: 3,
            mtime_nsec: 4,
            size: 5,
            mode: 0o100755,
        };
        assert_eq!(non_utf8_stamp.to_json(), None);
        let (pid7, input7) = spawn_cat();
        let non_utf8_front = Front {
            pid: pid7,
            input: input7,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_PION.to_string(),
            fallback_pion_stamp: Some(non_utf8_stamp),
            #[cfg(target_os = "macos")]
            launcher_uuid: None,
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let state = non_utf8_front.state();
        assert!(state.get("fallbackPionStamp").is_none());
        non_utf8_front.end();

        // 8. `streams < STREAMS` combined with MB -> Pion switch skips probing in `current_with` and returns `Ended`,
        //    so `resume()`'s `Front::start()` probes `--version` strictly once.
        let streams_probe_file = dir.join("streams-probe-count");
        let streams_pion = dir.join("streams-counting-pion");
        write_script(
            &streams_pion,
            &format!(
                "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 1 >> '{}'\n  echo 'stillfail-pion 0.1.0 modes:mesh'\n  exit 0\nfi\nprintf '{{\"listening\":\"%s\",\"streams\":8}}\\n' \"$4\"\nexec cat > /dev/null\n",
                streams_probe_file.display()
            ),
            true,
        );
        let (pid8, input8) = spawn_cat();
        let old_streams_mb = Front {
            pid: pid8,
            input: input8,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS - 1,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_MB.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert!(matches!(
            old_streams_mb.current_with(&app, Some(&cfg_pion), None, None, None, Some(streams_pion.as_os_str())),
            CurrentFront::Ended
        ));
        assert!(!streams_probe_file.exists(), "current_with must not probe when streams < STREAMS forces replacement");
        let resolved_streams = super::resolve_program_full(
            &app,
            Some(&cfg_pion),
            None,
            None,
            None,
            Some(streams_pion.as_os_str()),
            true,
        )
        .expect("resolved pion after streams replacement");
        let started_streams = Front::start_resolved_with(resolved_streams, &app, None, &data).expect("started pion");
        assert_eq!(started_streams.engine(), ENGINE_PION);
        started_streams.end();
        let streams_probes = std::fs::read_to_string(&streams_probe_file).unwrap().lines().count();
        assert_eq!(streams_probes, 1, "streams upgrade + MB -> Pion switch must run --version exactly once");

        // 9. `identity_changed` combined with MB -> Pion switch skips probing in `current_with_identity` and returns `Ended`,
        //    so `resume()`'s `Front::start()` probes `--version` strictly once.
        let id_probe_file = dir.join("id-probe-count");
        let id_pion = dir.join("id-counting-pion");
        write_script(
            &id_pion,
            &format!(
                "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  echo 1 >> '{}'\n  echo 'stillfail-pion 0.1.0 modes:mesh'\n  exit 0\nfi\nprintf '{{\"listening\":\"%s\",\"streams\":8}}\\n' \"$4\"\nexec cat > /dev/null\n",
                id_probe_file.display()
            ),
            true,
        );
        let (pid9, input9) = spawn_cat();
        let old_id_mb = Front {
            pid: pid9,
            input: input9,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_MB.to_string(),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: Some("old-uuid".to_string()),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert!(matches!(
            old_id_mb.current_with_identity(&app, Some(&cfg_pion), None, None, None, Some(id_pion.as_os_str()), true),
            CurrentFront::Ended
        ));
        assert!(!id_probe_file.exists(), "current_with_identity must not probe when identity_changed forces replacement");
        let resolved_id = super::resolve_program_full(
            &app,
            Some(&cfg_pion),
            None,
            None,
            None,
            Some(id_pion.as_os_str()),
            true,
        )
        .expect("resolved pion after identity replacement");
        let started_id = Front::start_resolved_with(resolved_id, &app, None, &data).expect("started pion");
        assert_eq!(started_id.engine(), ENGINE_PION);
        started_id.end();
        let id_probes = std::fs::read_to_string(&id_probe_file).unwrap().lines().count();
        assert_eq!(id_probes, 1, "identity change + MB -> Pion switch must run --version exactly once");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
