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

use std::collections::{BTreeMap, HashSet};
use std::ffi::{CString, OsStr};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
/// Unified default Pion rollout table by installed `<app>/CHANNEL` and canonical target.
/// Must stay 1:1 with `PION_DEFAULT_TARGETS_BY_CHANNEL` in `station/src/read/reader-select.ts`.
/// Stage 9A keeps both `beta` and `stable` empty (Zero Default Flip: all 4 targets default to `"mb"`).
const PION_DEFAULT_TARGETS_BY_CHANNEL: &[(&str, &[&str])] = &[
    ("beta", &[]),
    ("stable", &[]),
];
/// Persisted default-only Pion crash circuit breaker file under `<data>/run/`.
const DEMOTED_FILE: &str = "front-pion-demoted.json";
/// Persisted probe timeout backoff file under `<data>/run/` so `renew` `execv` preserves cooldown.
const PROBE_BACKOFF_FILE: &str = "front-probe-backoff.json";
/// Sliding-window crash threshold (`K = 3` within `N = 5 min`, millisecond precision matching TS `PionCircuitBreaker`).
const DEFAULT_BREAKER_THRESHOLD: usize = 3;
const DEFAULT_BREAKER_WINDOW_MS: u64 = 5 * 60 * 1000;
/// Monotonic sequence number for unique atomic temp filenames.
static DEMOTED_WRITE_SEQ: AtomicU64 = AtomicU64::new(0);
/// How long `--version` capability probing of `stillfail-pion` may take.
const PROBE_VERSION_WITHIN: Duration = Duration::from_secs(3);
/// Cooldown after a `--version` probe timeout for the same binary stamp (matches TS 30s cooldown).
const PROBE_TIMEOUT_COOLDOWN: Duration = Duration::from_secs(30);
/// Cap on bytes read from `stillfail-pion --version`.
const PROBE_STDOUT_LIMIT: usize = 64 * 1024;
/// How long it may take to listen.
const LISTENS_WITHIN: Duration = Duration::from_secs(10);

/// Backoff cache for timed-out `--version` probes: `(binary_path, stamp, retry_after)`.
static PROBE_TIMEOUT_BACKOFF: Mutex<Option<(PathBuf, Option<PionStamp>, Instant)>> = Mutex::new(None);
/// Process-local fallback breaker state keyed by `data` directory so ENOSPC / read-only `<data>/run`
/// still trips single-process K=3 default Pion demotion without dropping uncommitted failures.
static FRONT_BREAKER_MEM: Mutex<BTreeMap<PathBuf, BTreeMap<String, MemBreakerEntry>>> = Mutex::new(BTreeMap::new());
/// Deduplicated invalid/shadow wildcard values already warned about in `config.json readers.*`.
static WARNED_WILDCARD_VALUES: Mutex<Option<HashSet<String>>> = Mutex::new(None);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SelectSource {
    Env,
    Config,
    Default,
}

impl SelectSource {
    fn as_str(self) -> &'static str {
        match self {
            SelectSource::Env => "env",
            SelectSource::Config => "config",
            SelectSource::Default => "default",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "env" => Some(SelectSource::Env),
            "config" => Some(SelectSource::Config),
            "default" => Some(SelectSource::Default),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct ConfigReaders {
    mesh: Option<Value>,
    wildcard: Option<Value>,
}
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

    fn key(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}:{}:{}",
            self.path.to_string_lossy(),
            self.dev,
            self.ino,
            self.mtime_sec,
            self.mtime_nsec,
            self.size,
            self.mode
        )
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
    source: SelectSource,
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
    /// Immutable selection source (`default`, `config`, or `env`) captured when this front was spawned.
    /// Never rewritten by `decide_transition_with` on `Keep`; `None` when resumed from legacy state without source.
    spawn_source: Option<SelectSource>,
    /// Selection source that produced `fallback_pion_stamp` when `engine == "mb"` is running as a fallback from Pion.
    fallback_source: Option<SelectSource>,
    /// Stamp of the running Pion binary captured at spawn time (for default-only crash demotion).
    program_stamp: Option<PionStamp>,
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
        let config_readers = read_config_readers(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        let installed_channel = read_installed_channel(app);
        self.decide_transition_with(
            app,
            Some(data),
            &config_readers,
            mesh_env.as_deref(),
            global_env.as_deref(),
            mb_var.as_deref(),
            pion_var.as_deref(),
            installed_channel.as_deref(),
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
            true,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn decide_transition_with(
        &mut self,
        app: &Path,
        data: Option<&Path>,
        config_readers: &ConfigReaders,
        mesh_env: Option<&OsStr>,
        global_env: Option<&OsStr>,
        mb_var: Option<&OsStr>,
        pion_var: Option<&OsStr>,
        installed_channel: Option<&str>,
        target: Option<&str>,
        default_table: &[(&str, &[&str])],
        warn: bool,
    ) -> FrontDecision {
        let (requested, source) = select_requested_engine_with(
            mesh_env,
            config_readers,
            global_env,
            installed_channel,
            target,
            default_table,
            warn,
        );
        if requested == ENGINE_MB {
            if self.engine == ENGINE_MB {
                self.requested = ENGINE_MB.to_string();
                self.fallback_pion_stamp = None;
                self.fallback_source = None;
                return FrontDecision::Keep;
            }
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                return FrontDecision::SwitchTo(ResolvedProgram {
                    engine: ENGINE_MB.to_string(),
                    program: mb_program,
                    requested: ENGINE_MB.to_string(),
                    source,
                    fallback_pion_stamp: None,
                });
            }
            return FrontDecision::EndForDirectBind;
        }
        // requested == ENGINE_PION
        let pion_path = pion_candidate_with(app, pion_var);
        let current_stamp = PionStamp::of(&pion_path);
        if self.engine == ENGINE_PION {
            if is_executable_file(&pion_path) {
                self.requested = ENGINE_PION.to_string();
                self.fallback_pion_stamp = None;
                self.fallback_source = None;
                return FrontDecision::Keep;
            }
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                return FrontDecision::SwitchTo(ResolvedProgram {
                    engine: ENGINE_MB.to_string(),
                    program: mb_program,
                    requested: ENGINE_PION.to_string(),
                    source,
                    fallback_pion_stamp: current_stamp,
                });
            }
            return FrontDecision::EndForDirectBind;
        }
        // Running MB while policy requests Pion.
        if source == SelectSource::Default
            && data.is_some_and(|d| is_default_pion_demoted(d, current_stamp.as_ref()))
        {
            self.requested = ENGINE_PION.to_string();
            self.fallback_pion_stamp = current_stamp;
            self.fallback_source = Some(SelectSource::Default);
            return FrontDecision::Keep;
        }
        // If MB is running because of a default-policy demotion/fallback and an operator now explicitly requests
        // `pion` via Config or Env, do NOT swallow it with Keep: let it probe and retry Pion.
        let escalated_from_default =
            self.fallback_source == Some(SelectSource::Default) && source != SelectSource::Default;
        if !escalated_from_default
            && self.requested == ENGINE_PION
            && self.fallback_pion_stamp.is_some()
            && self.fallback_pion_stamp == current_stamp
        {
            // Same Pion binary we already fell back from under this policy: keep healthy MB front without probing.
            return FrontDecision::Keep;
        }
        if !is_executable_file(&pion_path) {
            if warn {
                log::warn(&format!("front mesh requested \"pion\" but {} is missing or not executable; keeping running \"mb\" front", pion_path.display()));
            }
            self.requested = ENGINE_PION.to_string();
            self.fallback_pion_stamp = current_stamp;
            self.fallback_source = Some(source);
            return FrontDecision::Keep;
        }
        if is_probe_timeout_in_cooldown(data, &pion_path, &current_stamp) {
            if warn {
                log::warn(&format!("front mesh requested \"pion\" but {} capability probe is in timeout cooldown; keeping running \"mb\" front", pion_path.display()));
            }
            return FrontDecision::Keep;
        }
        match probe_pion_mesh_support(&pion_path, PROBE_VERSION_WITHIN) {
            Ok(()) => {
                clear_probe_timeout_backoff(data, &pion_path);
                FrontDecision::SwitchTo(ResolvedProgram {
                    engine: ENGINE_PION.to_string(),
                    program: pion_path,
                    requested: ENGINE_PION.to_string(),
                    source,
                    fallback_pion_stamp: None,
                })
            }
            Err(ProbeError::TimedOut(reason)) => {
                // Record bounded cooldown for this stamp so a wedged binary does not block every handover for 3s.
                record_probe_timeout_backoff(data, &pion_path, current_stamp);
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
                self.fallback_source = Some(source);
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
        let config_readers = read_config_readers(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        let installed_channel = read_installed_channel(app);
        let (requested, _) = select_requested_engine_with(
            mesh_env.as_deref(),
            &config_readers,
            global_env.as_deref(),
            installed_channel.as_deref(),
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
            false,
        );
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
        let config_readers = read_config_readers(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        let installed_channel = read_installed_channel(app);
        let resolved = resolve_program_full(
            app,
            Some(data),
            &config_readers,
            mesh_env.as_deref(),
            global_env.as_deref(),
            mb_var.as_deref(),
            pion_var.as_deref(),
            installed_channel.as_deref(),
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
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
        let program_stamp = if resolved.engine == ENGINE_PION {
            PionStamp::of(&resolved.program)
        } else {
            None
        };
        let fallback_source = if resolved.fallback_pion_stamp.is_some() {
            Some(resolved.source)
        } else {
            None
        };
        if let Some(front) = spawn_front(
            &resolved.program,
            &resolved.engine,
            &resolved.requested,
            Some(resolved.source),
            fallback_source,
            program_stamp.clone(),
            resolved.fallback_pion_stamp.clone(),
            data,
        ) {
            return Some(front);
        }
        if resolved.engine == ENGINE_PION {
            if resolved.source == SelectSource::Default {
                if let Some(ref stamp) = program_stamp {
                    // Count startup/LISTENS_WITHIN failure as 1 failure in the K=3 / 5-min window (not immediate permanent demotion).
                    let demoted = record_default_pion_failure_at(data, stamp, now_unix_ms());
                    if demoted {
                        log::warn(&format!(
                            "the default-selected pion front ({}) reached {DEFAULT_BREAKER_THRESHOLD} failures within {}ms; demoting this binary stamp to \"mb\"",
                            stamp.path.display(),
                            DEFAULT_BREAKER_WINDOW_MS,
                        ));
                    }
                }
            }
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                log::warn(&format!("the front (engine pion, {}) failed to start or listen; falling back to \"mb\" ({})", resolved.program.display(), mb_program.display()));
                return spawn_front(&mb_program, ENGINE_MB, ENGINE_PION, Some(resolved.source), Some(resolved.source), None, program_stamp, data);
            }
        }
        None
    }

    /// It ended: another in its place, unless it ended sooner than `lives` after it started (said; the lifecycle tries
    /// again later: `front_gone`).
    /// For a default-selected Pion front, unexpected exits (when not `stopping` and not terminated by graceful
    /// `SIGTERM`/`SIGINT`/`SIGHUP`; note that for this long-lived front daemon an unexpected `exit(0)` while not
    /// stopping also counts as unexpected) are recorded in the K=3 / 5-min sliding window under `<data>/run/front-pion-demoted.json`.
    pub fn ended(self, app: &Path, data: &Path, status: libc::c_int, how: &str, stopping: bool, lives: Duration) -> Option<Front> {
        self.ended_at(app, data, status, how, stopping, lives, now_unix_ms())
    }

    fn ended_at(self, app: &Path, data: &Path, status: libc::c_int, how: &str, stopping: bool, lives: Duration, now_ms: u64) -> Option<Front> {
        if self.engine == ENGINE_PION
            && self.spawn_source == Some(SelectSource::Default)
            && should_count_front_exit(status, stopping)
        {
            if let Some(ref stamp) = self.program_stamp {
                let demoted = record_default_pion_failure_at(data, stamp, now_ms);
                if demoted {
                    log::warn(&format!(
                        "the default-selected pion front (pid {}, {}) {how} (threshold {DEFAULT_BREAKER_THRESHOLD}/{DEFAULT_BREAKER_WINDOW_MS}ms reached); demoting this binary stamp to \"mb\" until binary changes or config switches",
                        self.pid,
                        stamp.path.display(),
                    ));
                } else {
                    log::warn(&format!(
                        "the default-selected pion front (pid {}, {}) {how}; recorded failure in {DEFAULT_BREAKER_THRESHOLD}/{DEFAULT_BREAKER_WINDOW_MS}ms breaker window",
                        self.pid,
                        stamp.path.display(),
                    ));
                }
            }
        }
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
        if let Some(source) = self.spawn_source {
            state["spawnSource"] = json!(source.as_str());
        }
        if let Some(source) = self.fallback_source {
            state["fallbackSource"] = json!(source.as_str());
        }
        if let Some(stamp) = self.program_stamp.as_ref().and_then(PionStamp::to_json) {
            state["programStamp"] = stamp;
        }
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
        // Legacy launcher state without `spawnSource`/`source` stays `None` (never assumed to be `Default`).
        let spawn_source = state
            .get("spawnSource")
            .and_then(Value::as_str)
            .or_else(|| state.get("source").and_then(Value::as_str))
            .and_then(SelectSource::from_str);
        let fallback_source = state
            .get("fallbackSource")
            .and_then(Value::as_str)
            .and_then(SelectSource::from_str);
        let program_stamp = state.get("programStamp").and_then(PionStamp::from_json);
        let fallback_pion_stamp = state.get("fallbackPionStamp").and_then(PionStamp::from_json);
        Some(Front {
            pid, input: unsafe { OwnedFd::from_raw_fd(input) }, socket, pid_file, started: None,
            streams: state["streams"].as_u64().unwrap_or(1),
            engine,
            requested,
            spawn_source,
            fallback_source,
            program_stamp,
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
        let config_readers = read_config_readers(data);
        let mesh_env = std::env::var_os(MESH_ENGINE_VAR);
        let global_env = std::env::var_os(GLOBAL_ENGINE_VAR);
        let mb_var = std::env::var_os(PROGRAM_VAR);
        let pion_var = std::env::var_os(PION_PROGRAM_VAR);
        let installed_channel = read_installed_channel(app);
        self.current_with(
            app,
            Some(data),
            &config_readers,
            mesh_env.as_deref(),
            global_env.as_deref(),
            mb_var.as_deref(),
            pion_var.as_deref(),
            installed_channel.as_deref(),
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn current_with(
        self,
        app: &Path,
        data: Option<&Path>,
        config_readers: &ConfigReaders,
        mesh_env: Option<&OsStr>,
        global_env: Option<&OsStr>,
        mb_var: Option<&OsStr>,
        pion_var: Option<&OsStr>,
        installed_channel: Option<&str>,
        target: Option<&str>,
        default_table: &[(&str, &[&str])],
    ) -> CurrentFront {
        #[cfg(target_os = "macos")]
        let identity_changed = identity_needs_refresh(self.uuid_recorded, self.launcher_uuid.as_deref(), executable_uuid().as_deref());
        #[cfg(not(target_os = "macos"))]
        let identity_changed = false;
        self.current_with_identity(
            app,
            data,
            config_readers,
            mesh_env,
            global_env,
            mb_var,
            pion_var,
            installed_channel,
            target,
            default_table,
            identity_changed,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn current_with_identity(
        mut self,
        app: &Path,
        data: Option<&Path>,
        config_readers: &ConfigReaders,
        mesh_env: Option<&OsStr>,
        global_env: Option<&OsStr>,
        mb_var: Option<&OsStr>,
        pion_var: Option<&OsStr>,
        installed_channel: Option<&str>,
        target: Option<&str>,
        default_table: &[(&str, &[&str])],
        identity_changed: bool,
    ) -> CurrentFront {
        if identity_changed {
            log::warn(&format!("the front (pid {}) was started by another launcher identity: ending it so macOS can match its local network permission", self.pid));
        } else if self.streams < STREAMS {
            log::warn(&format!("the front (pid {}) hands streams as {} and this release as {STREAMS}: ending it for the release's", self.pid, self.streams));
        } else {
            return match self.decide_transition_with(
                app,
                data,
                config_readers,
                mesh_env,
                global_env,
                mb_var,
                pion_var,
                installed_channel,
                target,
                default_table,
                true,
            ) {
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
    spawn_source: Option<SelectSource>,
    fallback_source: Option<SelectSource>,
    program_stamp: Option<PionStamp>,
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
        // Newly spawned fronts must advertise at least `STREAMS` (older resumed fronts with `< STREAMS` are handled once in `current()`).
        Some((said, streams)) if said == socket.to_string_lossy() && streams >= STREAMS => {
            log::info(&format!("the front listens (pid {pid}, engine {engine}, {}): {}", program.display(), socket.display()));
            Some(Front {
                pid, input, socket, pid_file, started: Some(Instant::now()), streams,
                engine: engine.to_string(),
                requested: requested.to_string(),
                spawn_source,
                fallback_source,
                program_stamp,
                fallback_pion_stamp,
                #[cfg(target_os = "macos")]
                launcher_uuid: executable_uuid(),
                #[cfg(target_os = "macos")]
                uuid_recorded: true,
            })
        }
        other => {
            log::warn(&format!("the front (pid {pid}, engine {engine}) did not listen with streams >= {STREAMS} ({other:?}); each Node binds the station's endpoint itself"));
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

fn current_reader_target() -> Option<&'static str> {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    { Some("darwin-arm64") }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    { Some("linux-x64") }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    { Some("linux-arm64") }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    { Some("win32-x64") }
    #[cfg(not(any(
        all(target_os = "macos", target_arch = "aarch64"),
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "aarch64"),
        all(target_os = "windows", target_arch = "x86_64"),
    )))]
    { None }
}

/// Reads the installed release channel from `<app>/CHANNEL` (never `config.json`'s `updateChannel`).
fn read_installed_channel(app: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(app.join("CHANNEL")).ok()?;
    let trimmed = trim_es_whitespace(&raw);
    match trimmed {
        "stable" | "beta" => Some(trimmed.to_string()),
        _ => None,
    }
}

/// Resolves the default engine for `(installed_channel, target)` from `table`.
/// Missing/unknown channel or unknown target conservatively defaults to `"mb"`.
fn default_engine_for(
    installed_channel: Option<&str>,
    target: Option<&str>,
    table: &[(&str, &[&str])],
) -> &'static str {
    let Some(channel) = installed_channel.filter(|c| *c == "stable" || *c == "beta") else {
        return ENGINE_MB;
    };
    let Some(target) = target.filter(|t| !t.is_empty()) else {
        return ENGINE_MB;
    };
    for (ch, targets) in table {
        if *ch == channel && targets.contains(&target) {
            return ENGINE_PION;
        }
    }
    ENGINE_MB
}

fn now_unix_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

/// Normalize legacy Unix-second timestamps (`< 1_000_000_000_000`) to milliseconds for 1:1 parity with TS.
fn normalize_ts_ms(ts: u64) -> u64 {
    if ts > 0 && ts < 1_000_000_000_000 {
        ts.saturating_mul(1000)
    } else {
        ts
    }
}

/// Whether a reaped front exit status counts as an unexpected failure for the default-only Pion breaker.
/// - Launcher `stopping` phase never counts.
/// - Graceful shutdown signals (`SIGTERM`, `SIGINT`, `SIGHUP`) never count.
/// - Crash signals (`SIGSEGV`, `SIGABRT`, `SIGKILL`, etc.) always count.
/// - For this long-lived front daemon (which is expected to stay alive until stdin closes / launcher stops),
///   an unexpected `exit(0)` while `stopping == false` ALSO counts as an unexpected exit.
fn should_count_front_exit(status: libc::c_int, stopping: bool) -> bool {
    if stopping {
        return false;
    }
    if libc::WIFSIGNALED(status) {
        let sig = libc::WTERMSIG(status);
        return !matches!(sig, libc::SIGTERM | libc::SIGINT | libc::SIGHUP);
    }
    true
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FrontBreakerEntry {
    stamp: PionStamp,
    exits: Vec<u64>,
    demoted_at: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct MemBreakerEntry {
    stamp: PionStamp,
    pending_exits: Vec<u64>,
    demoted_at: Option<u64>,
}

fn demoted_file(data: &Path) -> PathBuf {
    data.join("run").join(DEMOTED_FILE)
}

fn probe_backoff_file(data: &Path) -> PathBuf {
    data.join("run").join(PROBE_BACKOFF_FILE)
}

fn read_front_breaker_entries(data: &Path) -> BTreeMap<String, FrontBreakerEntry> {
    let mut out = BTreeMap::new();
    let Ok(bytes) = std::fs::read(demoted_file(data)) else {
        return out;
    };
    let Ok(raw) = serde_json::from_slice::<Value>(&bytes) else {
        return out;
    };
    match raw.get("v").and_then(Value::as_u64) {
        Some(2) => {
            if let Some(entries) = raw.get("entries").and_then(Value::as_object) {
                for (key, val) in entries {
                    let Some(stamp) = val.get("stamp").and_then(PionStamp::from_json) else {
                        continue;
                    };
                    let exits = val
                        .get("exits")
                        .and_then(Value::as_array)
                        .map(|arr| arr.iter().filter_map(Value::as_u64).map(normalize_ts_ms).collect())
                        .unwrap_or_default();
                    let demoted_at = val.get("demotedAt").and_then(Value::as_u64).map(normalize_ts_ms);
                    out.insert(key.clone(), FrontBreakerEntry { stamp, exits, demoted_at });
                }
            }
        }
        Some(1) => {
            // Backward compatibility with v1 single-stamp demotion file.
            if let Some(stamp) = raw.get("stamp").and_then(PionStamp::from_json) {
                let key = stamp.key();
                out.insert(key, FrontBreakerEntry { stamp, exits: vec![], demoted_at: Some(0) });
            }
        }
        _ => {}
    }
    out
}

fn write_front_breaker_entries(data: &Path, entries: &BTreeMap<String, FrontBreakerEntry>) -> bool {
    let path = demoted_file(data);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut map = serde_json::Map::new();
    for (key, entry) in entries {
        let Some(stamp_json) = entry.stamp.to_json() else {
            continue;
        };
        let mut obj = serde_json::Map::new();
        obj.insert("stamp".to_string(), stamp_json);
        obj.insert("exits".to_string(), json!(entry.exits));
        if let Some(at) = entry.demoted_at {
            obj.insert("demotedAt".to_string(), json!(at));
        }
        map.insert(key.clone(), Value::Object(obj));
    }
    let payload = json!({ "v": 2, "entries": Value::Object(map) });
    let Ok(bytes) = serde_json::to_vec_pretty(&payload) else {
        return false;
    };
    let seq = DEMOTED_WRITE_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_extension(format!("json.{}.{seq}.tmp", std::process::id()));
    if let Err(error) = std::fs::write(&tmp, bytes).and_then(|_| std::fs::rename(&tmp, &path)) {
        log::warn(&format!("{}: {error}", path.display()));
        let _ = std::fs::remove_file(&tmp);
        return false;
    }
    true
}

/// Records one unexpected failure for `stamp` in the `K = 3` / `N = 5 min` sliding window under `<data>/run/front-pion-demoted.json`.
/// Tracks uncommitted `pending_exits` in process memory so readable stale disk files + ENOSPC/read-only write failures
/// never drop newly recorded failures, and clears `pending_exits` only once disk persistence succeeds.
/// Window boundary is strictly `ts > cutoff` in milliseconds (aligned 1:1 with TS `PionCircuitBreaker`).
fn record_default_pion_failure_at(data: &Path, stamp: &PionStamp, now_ms: u64) -> bool {
    record_default_pion_failure_at_with_writer(data, stamp, now_ms, write_front_breaker_entries)
}

fn record_default_pion_failure_at_with_writer<F>(data: &Path, stamp: &PionStamp, now_ms: u64, writer: F) -> bool
where
    F: FnOnce(&Path, &BTreeMap<String, FrontBreakerEntry>) -> bool,
{
    let mut mem_guard = FRONT_BREAKER_MEM.lock().unwrap_or_else(|e| e.into_inner());
    let mem_map = mem_guard.entry(data.to_path_buf()).or_default();
    let key = stamp.key();
    let cutoff = now_ms.saturating_sub(DEFAULT_BREAKER_WINDOW_MS);

    let mem_cur = mem_map.entry(key.clone()).or_insert_with(|| MemBreakerEntry {
        stamp: stamp.clone(),
        pending_exits: Vec::new(),
        demoted_at: None,
    });
    mem_cur.stamp = stamp.clone();
    mem_cur.pending_exits.retain(|&ts| ts > cutoff && ts <= now_ms);
    mem_cur.pending_exits.push(now_ms);

    let mut entries = read_front_breaker_entries(data);
    // Prune disk exits and merge uncommitted in-memory pending_exits + demoted_at for every stamp in this `data` dir.
    for (k, mem_entry) in mem_map.iter_mut() {
        mem_entry.pending_exits.retain(|&ts| ts > cutoff && ts <= now_ms);
        let disk_entry = entries.entry(k.clone()).or_insert_with(|| FrontBreakerEntry {
            stamp: mem_entry.stamp.clone(),
            exits: Vec::new(),
            demoted_at: None,
        });
        disk_entry.stamp = mem_entry.stamp.clone();
        disk_entry.exits.retain(|&ts| ts > cutoff && ts <= now_ms);
        disk_entry.exits.extend_from_slice(&mem_entry.pending_exits);
        if let Some(at) = mem_entry.demoted_at {
            disk_entry.demoted_at = Some(disk_entry.demoted_at.map_or(at, |d| d.min(at)));
        }
        if disk_entry.exits.len() >= DEFAULT_BREAKER_THRESHOLD && disk_entry.demoted_at.is_none() {
            disk_entry.demoted_at = Some(now_ms);
        }
        if let Some(at) = disk_entry.demoted_at {
            mem_entry.demoted_at = Some(mem_entry.demoted_at.map_or(at, |d| d.min(at)));
        }
    }

    let demoted = entries.get(&key).is_some_and(|e| e.demoted_at.is_some());
    let persisted = writer(data, &entries);
    if persisted {
        for mem_entry in mem_map.values_mut() {
            mem_entry.pending_exits.clear();
        }
    }
    demoted
}

/// Returns `true` if `current_stamp` is demoted in process memory or `<data>/run/front-pion-demoted.json`.
/// Never deletes other stamps' entries (binary replacement naturally gets a new stamp key).
fn is_default_pion_demoted(data: &Path, current_stamp: Option<&PionStamp>) -> bool {
    let Some(current) = current_stamp else {
        return false;
    };
    let key = current.key();
    {
        let mem_guard = FRONT_BREAKER_MEM.lock().unwrap_or_else(|e| e.into_inner());
        if mem_guard
            .get(data)
            .and_then(|m| m.get(&key))
            .is_some_and(|e| e.demoted_at.is_some())
        {
            return true;
        }
    }
    let entries = read_front_breaker_entries(data);
    entries.get(&key).is_some_and(|e| e.demoted_at.is_some())
}

fn is_probe_timeout_in_cooldown(data: Option<&Path>, path: &Path, current_stamp: &Option<PionStamp>) -> bool {
    {
        let mut guard = PROBE_TIMEOUT_BACKOFF.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((cached_path, cached_stamp, until)) = guard.as_ref() {
            if cached_path == path && cached_stamp == current_stamp {
                if Instant::now() < *until {
                    return true;
                }
                *guard = None;
            } else if cached_path == path {
                *guard = None;
            }
        }
    }
    // Check persisted backoff across launcher `renew` `execv`.
    let (Some(d), Some(stamp)) = (data, current_stamp.as_ref()) else {
        return false;
    };
    let Ok(bytes) = std::fs::read(probe_backoff_file(d)) else {
        return false;
    };
    let Ok(raw) = serde_json::from_slice::<Value>(&bytes) else {
        return false;
    };
    if raw.get("v").and_then(Value::as_u64) != Some(1) {
        return false;
    }
    let Some(saved_key) = raw.get("stampKey").and_then(Value::as_str) else {
        return false;
    };
    let Some(retry_after_ms) = raw.get("retryAfterMs").and_then(Value::as_u64) else {
        return false;
    };
    saved_key == stamp.key() && now_unix_ms() < retry_after_ms
}

fn record_probe_timeout_backoff(data: Option<&Path>, path: &Path, stamp: Option<PionStamp>) {
    {
        let mut guard = PROBE_TIMEOUT_BACKOFF.lock().unwrap_or_else(|e| e.into_inner());
        *guard = Some((path.to_path_buf(), stamp.clone(), Instant::now() + PROBE_TIMEOUT_COOLDOWN));
    }
    let (Some(d), Some(s)) = (data, stamp.as_ref()) else {
        return;
    };
    let file = probe_backoff_file(d);
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let retry_after_ms = now_unix_ms().saturating_add(PROBE_TIMEOUT_COOLDOWN.as_millis() as u64);
    let payload = json!({ "v": 1, "stampKey": s.key(), "retryAfterMs": retry_after_ms });
    if let Ok(bytes) = serde_json::to_vec(&payload) {
        let seq = DEMOTED_WRITE_SEQ.fetch_add(1, Ordering::Relaxed);
        let tmp = file.with_extension(format!("json.{}.{seq}.tmp", std::process::id()));
        if std::fs::write(&tmp, bytes).and_then(|_| std::fs::rename(&tmp, &file)).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

fn clear_probe_timeout_backoff(data: Option<&Path>, path: &Path) {
    {
        let mut guard = PROBE_TIMEOUT_BACKOFF.lock().unwrap_or_else(|e| e.into_inner());
        if guard.as_ref().is_some_and(|(p, _, _)| p == path) {
            *guard = None;
        }
    }
    if let Some(d) = data {
        let _ = std::fs::remove_file(probe_backoff_file(d));
    }
}

fn read_config_readers(data: &Path) -> ConfigReaders {
    let path = crate::data::var("CONFIG").map(PathBuf::from).unwrap_or_else(|| data.join("config.json"));
    read_config_readers_at(&path)
}

fn read_config_readers_at(path: &Path) -> ConfigReaders {
    let Ok(bytes) = std::fs::read(path) else {
        return ConfigReaders::default();
    };
    let Ok(raw) = serde_json::from_slice::<Value>(&bytes) else {
        return ConfigReaders::default();
    };
    let Some(readers) = raw.get("readers").and_then(Value::as_object) else {
        return ConfigReaders::default();
    };
    ConfigReaders {
        mesh: readers.get("mesh").cloned(),
        wildcard: readers.get("*").cloned(),
    }
}

fn parse_config_engine_value(val: &Value, source: &str, warn: bool) -> Option<&'static str> {
    match val {
        Value::Null => None,
        Value::String(s) if trim_es_whitespace(s).is_empty() => None,
        Value::String(s) => Some(parse_engine_str(s, source, warn)),
        other => {
            let emit = warn && (source != "config.json readers.*" || should_warn_wildcard_value(&other.to_string()));
            if emit {
                log::warn(&format!("invalid front mesh engine {other} from {source}; expected \"mb\" | \"pion\", falling back to \"mb\""));
            }
            Some(ENGINE_MB)
        }
    }
}

fn should_warn_wildcard_value(raw: &str) -> bool {
    let mut guard = WARNED_WILDCARD_VALUES.lock().unwrap_or_else(|e| e.into_inner());
    guard.get_or_insert_with(HashSet::new).insert(raw.to_string())
}

fn parse_engine_str(raw: &str, source: &str, warn: bool) -> &'static str {
    match trim_es_whitespace(raw).to_ascii_lowercase().as_str() {
        ENGINE_MB => ENGINE_MB,
        ENGINE_PION => ENGINE_PION,
        "shadow" => {
            let emit = warn && (source != "config.json readers.*" || should_warn_wildcard_value(raw));
            if emit {
                log::warn(&format!("front mesh engine {raw:?} from {source} forbids shadow execution; falling back to \"mb\""));
            }
            ENGINE_MB
        }
        _ => {
            let emit = warn && (source != "config.json readers.*" || should_warn_wildcard_value(raw));
            if emit {
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

/// Resolves the requested engine and its source for `--builder mesh` matching `station/src/read/reader-select.ts`:
/// `STILLFAIL_READER_MESH > config.json readers.mesh > config.json readers["*"] > STILLFAIL_READER_ENGINE > default`.
fn select_requested_engine_with(
    mesh_env: Option<&OsStr>,
    config_readers: &ConfigReaders,
    global_env: Option<&OsStr>,
    installed_channel: Option<&str>,
    target: Option<&str>,
    default_table: &[(&str, &[&str])],
    warn: bool,
) -> (&'static str, SelectSource) {
    if let Some(engine) = parse_engine_env(mesh_env, MESH_ENGINE_VAR, warn) {
        return (engine, SelectSource::Env);
    }
    if let Some(val) = config_readers.mesh.as_ref() {
        if let Some(engine) = parse_config_engine_value(val, "config.json readers.mesh", warn) {
            return (engine, SelectSource::Config);
        }
    }
    if let Some(val) = config_readers.wildcard.as_ref() {
        if let Some(engine) = parse_config_engine_value(val, "config.json readers.*", warn) {
            return (engine, SelectSource::Config);
        }
    }
    if let Some(engine) = parse_engine_env(global_env, GLOBAL_ENGINE_VAR, warn) {
        return (engine, SelectSource::Env);
    }
    (default_engine_for(installed_channel, target, default_table), SelectSource::Default)
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

fn resolve_bare_in_path(name: &Path, path_env: Option<&OsStr>) -> Option<PathBuf> {
    let path_env = path_env?;
    for dir in std::env::split_paths(path_env) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        let candidate = dir.join(name);
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn mb_program_with(app: &Path, mb_var: Option<&OsStr>) -> Option<PathBuf> {
    let path_env = std::env::var_os("PATH");
    mb_program_with_path(app, mb_var, path_env.as_deref())
}

fn mb_program_with_path(app: &Path, mb_var: Option<&OsStr>, path_env: Option<&OsStr>) -> Option<PathBuf> {
    if let Some(os) = mb_var.filter(|v| !v.is_empty()) {
        let candidate = match os.to_str() {
            Some(s) => {
                let trimmed = trim_es_whitespace(s);
                if trimmed.is_empty() {
                    None
                } else {
                    Some(PathBuf::from(trimmed))
                }
            }
            None => Some(PathBuf::from(os)),
        };
        if let Some(path) = candidate {
            // Explicit path with a separator (or leading `.`) must be an executable file on disk;
            // bare single-segment command names are resolved on PATH and verified executable;
            // bad explicit overrides fail closed rather than silently falling back to `<app>/station/stillfail-reader`.
            let raw_bytes = path.as_os_str().as_bytes();
            let has_path_syntax = raw_bytes.contains(&b'/') || raw_bytes.starts_with(b".");
            if has_path_syntax {
                let resolved = if path.is_absolute() {
                    path
                } else {
                    std::env::current_dir().ok().map(|cwd| cwd.join(&path)).unwrap_or(path)
                };
                return is_executable_file(&resolved).then_some(resolved);
            }
            return resolve_bare_in_path(&path, path_env);
        }
    }
    let program = app.join(PROGRAM_IN_APP);
    is_executable_file(&program).then_some(program)
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

#[allow(clippy::too_many_arguments)]
fn resolve_program_full(
    app: &Path,
    data: Option<&Path>,
    config_readers: &ConfigReaders,
    mesh_env: Option<&OsStr>,
    global_env: Option<&OsStr>,
    mb_var: Option<&OsStr>,
    pion_var: Option<&OsStr>,
    installed_channel: Option<&str>,
    target: Option<&str>,
    default_table: &[(&str, &[&str])],
    warn: bool,
) -> Option<ResolvedProgram> {
    let (requested, source) = select_requested_engine_with(
        mesh_env,
        config_readers,
        global_env,
        installed_channel,
        target,
        default_table,
        warn,
    );
    let mut fallback_pion_stamp = None;
    if requested == ENGINE_PION {
        let pion_path = pion_candidate_with(app, pion_var);
        let current_stamp = PionStamp::of(&pion_path);
        let demoted = source == SelectSource::Default
            && data.is_some_and(|d| is_default_pion_demoted(d, current_stamp.as_ref()));
        if demoted {
            if let Some(mb_program) = mb_program_with(app, mb_var) {
                if warn {
                    log::warn(&format!("front mesh defaulted to \"pion\" but {} is demoted after prior crash; falling back to \"mb\"", pion_path.display()));
                }
                return Some(ResolvedProgram {
                    engine: ENGINE_MB.to_string(),
                    program: mb_program,
                    requested: ENGINE_PION.to_string(),
                    source,
                    fallback_pion_stamp: current_stamp,
                });
            }
            if warn {
                log::warn(&format!("front mesh defaulted to \"pion\" and {} is demoted, but no MB binary is available; staying on \"pion\"", pion_path.display()));
            }
        }
        if !is_executable_file(&pion_path) {
            fallback_pion_stamp = current_stamp;
            if warn {
                log::warn(&format!("front mesh requested \"pion\" but {} is missing or not executable; falling back to \"mb\"", pion_path.display()));
            }
        } else if is_probe_timeout_in_cooldown(data, &pion_path, &current_stamp) {
            if warn {
                log::warn(&format!("front mesh requested \"pion\" but {} capability probe is in timeout cooldown; falling back to \"mb\"", pion_path.display()));
            }
        } else {
            match probe_pion_mesh_support(&pion_path, PROBE_VERSION_WITHIN) {
                Ok(()) => {
                    clear_probe_timeout_backoff(data, &pion_path);
                    return Some(ResolvedProgram {
                        engine: ENGINE_PION.to_string(),
                        program: pion_path,
                        requested: ENGINE_PION.to_string(),
                        source,
                        fallback_pion_stamp: None,
                    });
                }
                Err(ProbeError::TimedOut(reason)) => {
                    record_probe_timeout_backoff(data, &pion_path, current_stamp);
                    if warn {
                        log::warn(&format!("front mesh requested \"pion\" but {} capability probe timed out ({reason}); falling back to \"mb\"", pion_path.display()));
                    }
                }
                Err(ProbeError::Deterministic(reason)) => {
                    fallback_pion_stamp = current_stamp;
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
        source,
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
    let readers = ConfigReaders { mesh: config_mesh.cloned(), wildcard: None };
    resolve_program_full(
        app,
        None,
        &readers,
        mesh_env,
        global_env,
        mb_var,
        pion_var,
        None,
        current_reader_target(),
        PION_DEFAULT_TARGETS_BY_CHANNEL,
        warn,
    )
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
    let path = said["listening"].as_str().filter(|s| !s.is_empty())?;
    let streams = match said.get("streams") {
        None => 1,
        Some(v) => v.as_u64().filter(|&n| n >= 1)?,
    };
    Some((path.to_string(), streams))
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
        ConfigReaders, CurrentFront, DEFAULT_BREAKER_THRESHOLD, DEFAULT_BREAKER_WINDOW_MS,
        ENGINE_MB, ENGINE_PION, Front, FrontDecision, PION_DEFAULT_TARGETS_BY_CHANNEL,
        PROBE_STDOUT_LIMIT, PionStamp, ProbeError, ResolvedProgram, STREAMS, SelectSource,
        clear_probe_timeout_backoff, current_reader_target, default_engine_for,
        infer_engine_from_args, is_default_pion_demoted, listening, mb_program_with,
        mb_program_with_path, probe_pion_mesh_support, read_config_readers_at,
        read_front_breaker_entries, read_installed_channel, record_default_pion_failure_at,
        record_default_pion_failure_at_with_writer, resolve_override_path, resolve_program_full,
        resolve_program_with, select_requested_engine_with, should_count_front_exit,
        version_supports_mesh,
    };
    use std::os::unix::process::CommandExt;
    use serde_json::{Value, json};
    use std::ffi::{OsStr, OsString};
    use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    static SEQ: AtomicU64 = AtomicU64::new(0);
    static EXEC_LOCK: Mutex<()> = Mutex::new(());

    fn select_requested_engine(
        mesh_env: Option<&OsStr>,
        config_mesh: Option<&Value>,
        global_env: Option<&OsStr>,
        warn: bool,
    ) -> &'static str {
        let readers = ConfigReaders { mesh: config_mesh.cloned(), wildcard: None };
        select_requested_engine_with(
            mesh_env,
            &readers,
            global_env,
            None,
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
            warn,
        )
        .0
    }

    fn cfg_mesh(v: &Value) -> ConfigReaders {
        ConfigReaders { mesh: Some(v.clone()), wildcard: None }
    }

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
            assert_eq!(read_config_readers_at(&cfg_path), ConfigReaders::default());
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
    fn relative_pion_override_resolves_to_cwd_while_mb_verifies_path_lookup() {
        let resolved = resolve_override_path(os("stillfail-pion")).expect("resolved");
        assert!(resolved.is_absolute(), "pion override must be absolute: {}", resolved.display());
        assert_eq!(resolved.file_name().and_then(|n| n.to_str()), Some("stillfail-pion"));
        assert_eq!(resolve_override_path(os("  \u{FEFF} ")), None);

        // STILLFAIL_MB_READER bare command resolves via PATH and requires executable file.
        let dir = temp_dir("mb-path-lookup");
        let bin_dir = dir.join("bin");
        let mb_bin = bin_dir.join("custom-mb-reader");
        write_script(&mb_bin, "#!/bin/sh\necho mb\n", true);
        let nonexec_bin = bin_dir.join("nonexec-mb-reader");
        write_script(&nonexec_bin, "#!/bin/sh\necho mb\n", false);
        let path_env = bin_dir.as_os_str();

        assert_eq!(mb_program_with_path(Path::new("/nonexistent-app"), os("custom-mb-reader"), Some(path_env)), Some(mb_bin));
        assert_eq!(mb_program_with_path(Path::new("/nonexistent-app"), os("nonexec-mb-reader"), Some(path_env)), None);
        assert_eq!(mb_program_with_path(Path::new("/nonexistent-app"), os("missing-mb-reader"), Some(path_env)), None);
        let _ = std::fs::remove_dir_all(&dir);
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
        let cfg_val = read_config_readers_at(&cfg_path);
        let resolved_cfg = resolve_program_with(&app, cfg_val.mesh.as_ref(), None, None, None, Some(OsStr::new("  ")), false);
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

        // Round-trip with engine = "mb", requested = "pion", spawn_source = Some(Config), fallback_source = Some(Config), fallback_pion_stamp = Some(stamp).
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
            spawn_source: Some(SelectSource::Config),
            fallback_source: Some(SelectSource::Config),
            program_stamp: None,
            fallback_pion_stamp: Some(stamp.clone()),
            #[cfg(target_os = "macos")]
            launcher_uuid: None,
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let serialized = front.state();
        assert_eq!(serialized["engine"], json!("mb"));
        assert_eq!(serialized["requested"], json!("pion"));
        assert_eq!(serialized["spawnSource"], json!("config"));
        assert_eq!(serialized["fallbackSource"], json!("config"));
        let Front { input, .. } = front;
        let _leaked = input.into_raw_fd();
        let resumed = Front::resumed(&serialized).expect("resumed front");
        assert_eq!(resumed.engine(), ENGINE_MB);
        assert_eq!(resumed.requested, ENGINE_PION);
        assert_eq!(resumed.spawn_source, Some(SelectSource::Config));
        assert_eq!(resumed.fallback_source, Some(SelectSource::Config));
        assert_eq!(resumed.fallback_pion_stamp, Some(stamp));
        assert_eq!(resumed.pid, 4242);
        drop(resumed);

        // Old launcher state without "engine"/"requested"/"spawnSource" defaults safely to "mb" and leaves spawn_source = None (NEVER Default).
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
        assert_eq!(resumed_old.spawn_source, None);
        assert_eq!(resumed_old.fallback_source, None);
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
            spawn_source: Some(SelectSource::Config),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let kept = match kept.current_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, None, None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL) {
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
            spawn_source: Some(SelectSource::Default),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert!(matches!(
            old.current_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, None, None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL),
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
            spawn_source: Some(SelectSource::Default),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            healthy_mb.decide_transition_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, Some(bad_pion.as_os_str()), None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL, false),
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
            spawn_source: Some(SelectSource::Config),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            pion_only.decide_transition_with(&pion_only_app, Some(&data), &cfg_mesh(&cfg_mb), None, None, None, None, None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL, false),
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
            spawn_source: Some(SelectSource::Default),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            waiting_mb.decide_transition_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, Some(chmod_pion.as_os_str()), None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL, false),
            FrontDecision::Keep
        );
        assert_eq!(waiting_mb.fallback_pion_stamp.as_ref(), Some(&stamp_before));
        std::fs::set_permissions(&chmod_pion, std::fs::Permissions::from_mode(0o755)).unwrap();
        let stamp_after = PionStamp::of(&chmod_pion).expect("stamp after chmod");
        assert_ne!(stamp_before.mode, stamp_after.mode);
        assert!(matches!(
            waiting_mb.decide_transition_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, Some(chmod_pion.as_os_str()), None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL, false),
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
            spawn_source: Some(SelectSource::Default),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        let resolved = match mb_switch.current_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, Some(counting_pion.as_os_str()), None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL) {
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
            spawn_source: Some(SelectSource::Config),
            fallback_source: None,
            program_stamp: None,
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
            spawn_source: Some(SelectSource::Default),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: super::executable_uuid(),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert!(matches!(
            old_streams_mb.current_with(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, Some(streams_pion.as_os_str()), None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL),
            CurrentFront::Ended
        ));
        assert!(!streams_probe_file.exists(), "current_with must not probe when streams < STREAMS forces replacement");
        let resolved_streams = resolve_program_full(
            &app,
            Some(&data),
            &cfg_mesh(&cfg_pion),
            None,
            None,
            None,
            Some(streams_pion.as_os_str()),
            None,
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
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
            spawn_source: Some(SelectSource::Default),
            fallback_source: None,
            program_stamp: None,
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: Some("old-uuid".to_string()),
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert!(matches!(
            old_id_mb.current_with_identity(&app, Some(&data), &cfg_mesh(&cfg_pion), None, None, None, Some(id_pion.as_os_str()), None, current_reader_target(), PION_DEFAULT_TARGETS_BY_CHANNEL, true),
            CurrentFront::Ended
        ));
        assert!(!id_probe_file.exists(), "current_with_identity must not probe when identity_changed forces replacement");
        let resolved_id = resolve_program_full(
            &app,
            Some(&data),
            &cfg_mesh(&cfg_pion),
            None,
            None,
            None,
            Some(id_pion.as_os_str()),
            None,
            current_reader_target(),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
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

    #[test]
    fn default_policy_table_and_wildcard_precedence_matrix() {
        // Stage 9A Zero Default Flip: production table keeps beta and stable empty for all 4 targets.
        let targets = ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"];
        for target in targets {
            for ch in [Some("beta"), Some("stable"), Some("nightly"), None] {
                assert_eq!(default_engine_for(ch, Some(target), PION_DEFAULT_TARGETS_BY_CHANNEL), ENGINE_MB);
            }
        }

        // Injected Stage 9B table verifies all 4 targets x (beta, stable, unknown, missing).
        let stage_9b: &[(&str, &[&str])] = &[
            ("beta", &["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"]),
            ("stable", &["linux-x64"]),
        ];
        for target in targets {
            assert_eq!(default_engine_for(Some("beta"), Some(target), stage_9b), ENGINE_PION);
            assert_eq!(default_engine_for(None, Some(target), stage_9b), ENGINE_MB);
            assert_eq!(default_engine_for(Some("dev"), Some(target), stage_9b), ENGINE_MB);
        }
        assert_eq!(default_engine_for(Some("stable"), Some("linux-x64"), stage_9b), ENGINE_PION);
        assert_eq!(default_engine_for(Some("stable"), Some("darwin-arm64"), stage_9b), ENGINE_MB);

        // Precedence: STILLFAIL_READER_MESH > config.readers.mesh > config.readers["*"] > STILLFAIL_READER_ENGINE > default.
        let wildcard_mb = ConfigReaders { mesh: None, wildcard: Some(json!("mb")) };
        let wildcard_pion = ConfigReaders { mesh: None, wildcard: Some(json!("pion")) };
        let mesh_mb_wild_pion = ConfigReaders { mesh: Some(json!("mb")), wildcard: Some(json!("pion")) };
        let mesh_blank_wild_pion = ConfigReaders { mesh: Some(json!("  ")), wildcard: Some(json!("pion")) };

        // Wildcard config overrides STILLFAIL_READER_ENGINE and default table.
        assert_eq!(
            select_requested_engine_with(None, &wildcard_mb, os("pion"), Some("beta"), Some("linux-x64"), stage_9b, false),
            (ENGINE_MB, SelectSource::Config)
        );
        assert_eq!(
            select_requested_engine_with(None, &wildcard_pion, os("mb"), None, Some("linux-x64"), stage_9b, false),
            (ENGINE_PION, SelectSource::Config)
        );
        // Per-mode config overrides wildcard.
        assert_eq!(
            select_requested_engine_with(None, &mesh_mb_wild_pion, os("pion"), Some("beta"), Some("linux-x64"), stage_9b, false),
            (ENGINE_MB, SelectSource::Config)
        );
        // Blank per-mode config falls through to wildcard.
        assert_eq!(
            select_requested_engine_with(None, &mesh_blank_wild_pion, os("mb"), None, Some("linux-x64"), stage_9b, false),
            (ENGINE_PION, SelectSource::Config)
        );
        // Per-mode env overrides wildcard.
        assert_eq!(
            select_requested_engine_with(os("mb"), &wildcard_pion, os("pion"), Some("beta"), Some("linux-x64"), stage_9b, false),
            (ENGINE_MB, SelectSource::Env)
        );
        // Invalid wildcard value fails safe to mb without falling through to global env or default.
        let wildcard_bad = ConfigReaders { mesh: None, wildcard: Some(json!("shadow")) };
        assert_eq!(
            select_requested_engine_with(None, &wildcard_bad, os("pion"), Some("beta"), Some("linux-x64"), stage_9b, false),
            (ENGINE_MB, SelectSource::Config)
        );

        // Installed CHANNEL file is read from <app>/CHANNEL (strictly ignoring config.updateChannel).
        let dir = temp_dir("channel");
        assert_eq!(read_installed_channel(&dir), None);
        std::fs::write(dir.join("CHANNEL"), "beta\n").unwrap();
        assert_eq!(read_installed_channel(&dir).as_deref(), Some("beta"));
        std::fs::write(dir.join("CHANNEL"), "unknown\n").unwrap();
        assert_eq!(read_installed_channel(&dir), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bad_mb_override_and_malformed_streams_handshake_fail_closed() {
        let dir = temp_dir("bad-override-streams");
        let app = dir.join("app");
        let app_mb = app.join("station/stillfail-reader");
        write_script(&app_mb, "#!/bin/sh\necho mb\n", true);

        // Blank STILLFAIL_MB_READER falls through to <app>/station/stillfail-reader.
        assert_eq!(mb_program_with(&app, os("   \t ")), Some(app_mb.clone()));
        // Nonexistent explicit path fails closed (does NOT fall through to app's stillfail-reader).
        let missing = dir.join("missing-mb");
        assert_eq!(mb_program_with(&app, Some(missing.as_os_str())), None);
        // Non-executable explicit path fails closed.
        let nonexec = dir.join("nonexec-mb");
        write_script(&nonexec, "#!/bin/sh\necho mb\n", false);
        assert_eq!(mb_program_with(&app, Some(nonexec.as_os_str())), None);

        // listening() validates non-empty socket path and positive integer `streams` (omitted -> 1).
        let parse_line = |line: &str| -> Option<(String, u64)> {
            let mut child = Command::new("/bin/sh")
                .args(["-c", &format!("printf '%s\\n' '{}'", line.replace('\'', "'\\''"))])
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            let mut out = child.stdout.take().unwrap();
            let res = listening(&mut out);
            let _ = child.wait();
            res
        };
        assert_eq!(parse_line(r#"{"listening":"/tmp/a.sock","streams":8}"#), Some(("/tmp/a.sock".to_string(), 8)));
        assert_eq!(parse_line(r#"{"listening":"/tmp/a.sock"}"#), Some(("/tmp/a.sock".to_string(), 1)));
        assert_eq!(parse_line(r#"{"listening":"","streams":8}"#), None);
        assert_eq!(parse_line(r#"{"listening":"/tmp/a.sock","streams":0}"#), None);
        assert_eq!(parse_line(r#"{"listening":"/tmp/a.sock","streams":-1}"#), None);
        assert_eq!(parse_line(r#"{"listening":"/tmp/a.sock","streams":"8"}"#), None);
        assert_eq!(parse_line(r#"{"listening":"/tmp/a.sock","streams":null}"#), None);

        let _ = std::fs::remove_dir_all(&dir);
    }

    fn real_wait_status(sh_cmd: &str) -> libc::c_int {
        let child = Command::new("/bin/sh").args(["-c", sh_cmd]).spawn().unwrap();
        let pid = child.id() as libc::pid_t;
        let mut status: libc::c_int = 0;
        let rc = unsafe { libc::waitpid(pid, &mut status, 0) };
        assert_eq!(rc, pid);
        status
    }

    /// Produces a real `waitpid` signal status even when the parent shell (e.g. GitHub Actions non-interactive shell)
    /// inherited `SIG_IGN` for `SIGINT` or `SIGQUIT`, by restoring `SIG_DFL` in `pre_exec` before signaling.
    fn real_wait_status_sig(sig: libc::c_int) -> libc::c_int {
        let mut cmd = Command::new("/bin/sleep");
        cmd.arg("60");
        unsafe {
            cmd.pre_exec(move || {
                libc::signal(sig, libc::SIG_DFL);
                Ok(())
            });
        }
        let child = cmd.spawn().unwrap();
        let pid = child.id() as libc::pid_t;
        unsafe { libc::kill(pid, sig) };
        let mut status: libc::c_int = 0;
        let rc = unsafe { libc::waitpid(pid, &mut status, 0) };
        assert_eq!(rc, pid);
        assert!(libc::WIFSIGNALED(status), "expected signal {sig}, got raw status {status}");
        assert_eq!(libc::WTERMSIG(status), sig);
        status
    }

    #[test]
    fn default_pion_breaker_uses_k3_5min_window_filters_signals_and_stopping_and_recovers_on_upgrade() {
        let _exec = EXEC_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("default-demote");
        let app = dir.join("app");
        let data = dir.join("data");
        std::fs::create_dir_all(data.join("run")).unwrap();
        let mb_bin = app.join("station/stillfail-reader");
        let pion_bin = app.join("station/stillfail-pion");
        write_script(&mb_bin, "#!/bin/sh\necho mb\n", true);
        write_script(&pion_bin, "#!/bin/sh\necho 'stillfail-pion 0.3.0 modes:mesh'\n", true);
        let stamp_a = PionStamp::of(&pion_bin).expect("stamp a");
        let stage_9b: &[(&str, &[&str])] = &[("beta", &["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"])];

        // 0. Real waitpid statuses: SIGTERM/SIGINT/SIGHUP and stopping=true are ignored; exit(0), exit(1), SIGKILL when not stopping count.
        let st_exit0 = real_wait_status("exit 0");
        let st_exit1 = real_wait_status("exit 1");
        let st_sigterm = real_wait_status_sig(libc::SIGTERM);
        let st_sigint = real_wait_status_sig(libc::SIGINT);
        let st_sighup = real_wait_status_sig(libc::SIGHUP);
        let st_sigkill = real_wait_status_sig(libc::SIGKILL);

        assert!(!should_count_front_exit(st_sigterm, false));
        assert!(!should_count_front_exit(st_sigint, false));
        assert!(!should_count_front_exit(st_sighup, false));
        assert!(!should_count_front_exit(st_exit1, true));
        assert!(!should_count_front_exit(st_sigkill, true));
        assert!(should_count_front_exit(st_exit0, false), "unexpected exit(0) of long-lived front while not stopping counts");
        assert!(should_count_front_exit(st_exit1, false));
        assert!(should_count_front_exit(st_sigkill, false));

        let make_default_pion_front = |stamp: &PionStamp| -> Front {
            let mut child = Command::new("/bin/cat").stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap();
            let pid = child.id() as i32;
            let input = unsafe { OwnedFd::from_raw_fd(child.stdin.take().unwrap().into_raw_fd()) };
            drop(child);
            Front {
                pid,
                input,
                socket: data.join("run/front.sock"),
                pid_file: data.join("run/front.pid"),
                started: Some(Instant::now()),
                streams: STREAMS,
                engine: ENGINE_PION.to_string(),
                requested: ENGINE_PION.to_string(),
                spawn_source: Some(SelectSource::Default),
                fallback_source: None,
                program_stamp: Some(stamp.clone()),
                fallback_pion_stamp: None,
                #[cfg(target_os = "macos")]
                launcher_uuid: None,
                #[cfg(target_os = "macos")]
                uuid_recorded: true,
            }
        };

        // 1. SIGTERM and stopping=true do NOT increment the breaker.
        let t0 = 1_700_000_000_000u64;
        assert!(make_default_pion_front(&stamp_a).ended_at(&app, &data, st_sigterm, "signal 15", false, Duration::from_secs(60), t0).is_none());
        assert!(make_default_pion_front(&stamp_a).ended_at(&app, &data, st_exit1, "exited 1", true, Duration::from_secs(60), t0 + 1_000).is_none());
        assert!(read_front_breaker_entries(&data).is_empty());

        // 2. K = 3 within N = 5 min sliding window (ms precision): 2 exits inside window do NOT demote; an exit older than 5 min expires.
        assert!(make_default_pion_front(&stamp_a).ended_at(&app, &data, st_exit1, "exited 1", false, Duration::from_secs(60), t0).is_none());
        assert!(!is_default_pion_demoted(&data, Some(&stamp_a)));
        assert!(make_default_pion_front(&stamp_a).ended_at(&app, &data, st_exit0, "exited 0", false, Duration::from_secs(60), t0 + 60_000).is_none());
        assert!(!is_default_pion_demoted(&data, Some(&stamp_a)));
        // 3rd exit after > 5 min (t0 + 300_001ms) prunes t0, leaving 2 exits -> still NOT demoted.
        assert!(make_default_pion_front(&stamp_a).ended_at(&app, &data, st_sigkill, "signal 9", false, Duration::from_secs(60), t0 + DEFAULT_BREAKER_WINDOW_MS + 1).is_none());
        assert!(!is_default_pion_demoted(&data, Some(&stamp_a)));
        // 4th exit at t0 + 300_002ms makes 3 exits within 5 min -> DEMOTED!
        assert!(make_default_pion_front(&stamp_a).ended_at(&app, &data, st_exit1, "exited 1", false, Duration::from_secs(60), t0 + DEFAULT_BREAKER_WINDOW_MS + 2).is_none());
        assert!(is_default_pion_demoted(&data, Some(&stamp_a)));
        assert_eq!(DEFAULT_BREAKER_THRESHOLD, 3);

        // 3. Subsequent default resolution falls back to MB for the same stamp.
        let resolved_demoted = resolve_program_full(
            &app,
            Some(&data),
            &ConfigReaders::default(),
            None,
            None,
            None,
            None,
            Some("beta"),
            Some("linux-x64"),
            stage_9b,
            false,
        )
        .expect("fallback to mb");
        assert_eq!(resolved_demoted.engine, ENGINE_MB);
        assert_eq!(resolved_demoted.requested, ENGINE_PION);
        assert_eq!(resolved_demoted.source, SelectSource::Default);
        assert_eq!(resolved_demoted.fallback_pion_stamp, Some(stamp_a.clone()));

        // 4. Explicit config.readers.mesh = "pion" is NOT blocked by default-only demotion, AND on a running
        //    default-fallback MB front, decide_transition_with escalates to SwitchTo(pion) instead of Keep!
        let mut child_mb = Command::new("/bin/cat").stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap();
        let pid_mb = child_mb.id() as i32;
        let input_mb = unsafe { OwnedFd::from_raw_fd(child_mb.stdin.take().unwrap().into_raw_fd()) };
        drop(child_mb);
        let mut demoted_mb = Front {
            pid: pid_mb,
            input: input_mb,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_MB.to_string(),
            requested: ENGINE_PION.to_string(),
            spawn_source: Some(SelectSource::Default),
            fallback_source: Some(SelectSource::Default),
            program_stamp: None,
            fallback_pion_stamp: Some(stamp_a.clone()),
            #[cfg(target_os = "macos")]
            launcher_uuid: None,
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        // Under Default policy, stays Keep.
        assert_eq!(
            demoted_mb.decide_transition_with(&app, Some(&data), &ConfigReaders::default(), None, None, None, None, Some("beta"), Some("linux-x64"), stage_9b, false),
            FrontDecision::Keep
        );
        // Under explicit Config "pion", MUST NOT be swallowed by Keep: switches to Pion!
        assert!(matches!(
            demoted_mb.decide_transition_with(&app, Some(&data), &cfg_mesh(&json!("pion")), None, None, None, None, Some("beta"), Some("linux-x64"), stage_9b, false),
            FrontDecision::SwitchTo(ref r) if r.engine == ENGINE_PION && r.source == SelectSource::Config
        ));
        demoted_mb.end();

        // 5. Immutable spawn_source: a Pion front spawned by Config keeps spawn_source == Some(Config) even after
        //    config is removed and Default policy takes over on Keep.
        let mut child_cfg = Command::new("/bin/cat").stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap();
        let pid_cfg = child_cfg.id() as i32;
        let input_cfg = unsafe { OwnedFd::from_raw_fd(child_cfg.stdin.take().unwrap().into_raw_fd()) };
        drop(child_cfg);
        let mut cfg_pion = Front {
            pid: pid_cfg,
            input: input_cfg,
            socket: data.join("run/front.sock"),
            pid_file: data.join("run/front.pid"),
            started: None,
            streams: STREAMS,
            engine: ENGINE_PION.to_string(),
            requested: ENGINE_PION.to_string(),
            spawn_source: Some(SelectSource::Config),
            fallback_source: None,
            program_stamp: Some(stamp_a.clone()),
            fallback_pion_stamp: None,
            #[cfg(target_os = "macos")]
            launcher_uuid: None,
            #[cfg(target_os = "macos")]
            uuid_recorded: true,
        };
        assert_eq!(
            cfg_pion.decide_transition_with(&app, Some(&data), &ConfigReaders::default(), None, None, None, None, Some("beta"), Some("linux-x64"), stage_9b, false),
            FrontDecision::Keep
        );
        assert_eq!(cfg_pion.spawn_source, Some(SelectSource::Config), "Keep must never rewrite spawn_source");
        cfg_pion.end();

        // 6. When no MB binary exists, demoted default Pion safely stays on Pion without failing.
        let missing_mb = dir.join("no-mb");
        let resolved_no_mb = resolve_program_full(
            &app,
            Some(&data),
            &ConfigReaders::default(),
            None,
            None,
            Some(missing_mb.as_os_str()),
            None,
            Some("beta"),
            Some("linux-x64"),
            stage_9b,
            false,
        )
        .expect("stay on pion when no mb exists");
        assert_eq!(resolved_no_mb.engine, ENGINE_PION);

        // 7. Replacing the Pion binary on disk gives a new stamp key (not demoted), WITHOUT deleting stamp_a's entry.
        write_script(&pion_bin, "#!/bin/sh\necho 'stillfail-pion 0.3.1 modes:mesh'\n", true);
        let stamp_b = PionStamp::of(&pion_bin).expect("stamp b");
        assert_ne!(stamp_a, stamp_b);
        let resolved_upgraded = resolve_program_full(
            &app,
            Some(&data),
            &ConfigReaders::default(),
            None,
            None,
            None,
            None,
            Some("beta"),
            Some("linux-x64"),
            stage_9b,
            false,
        )
        .expect("recovered pion after upgrade");
        assert_eq!(resolved_upgraded.engine, ENGINE_PION);
        assert!(!is_default_pion_demoted(&data, Some(&stamp_b)));
        assert!(is_default_pion_demoted(&data, Some(&stamp_a)), "checking stamp_b must not delete stamp_a");
        // Recording a failure on stamp_a never affects stamp_b.
        record_default_pion_failure_at(&data, &stamp_a, t0 + 400);
        assert!(!is_default_pion_demoted(&data, Some(&stamp_b)));

        // 8. Probe timeout cooldown skips re-probing a wedged binary on consecutive handovers AND persists across renew execv.
        let slow_pion = dir.join("slow-pion");
        write_script(&slow_pion, "#!/bin/sh\nsleep 5\n", true);
        let slow_stamp = PionStamp::of(&slow_pion);
        super::record_probe_timeout_backoff(Some(&data), &slow_pion, slow_stamp.clone());
        // Simulate launcher `renew` `execv`: wipe in-memory backoff cache, disk file must still enforce cooldown!
        clear_probe_timeout_backoff(None, &slow_pion);
        let t_probe = Instant::now();
        let skipped = resolve_program_full(
            &app,
            Some(&data),
            &cfg_mesh(&json!("pion")),
            None,
            None,
            None,
            Some(slow_pion.as_os_str()),
            None,
            Some("linux-x64"),
            PION_DEFAULT_TARGETS_BY_CHANNEL,
            false,
        )
        .expect("mb during timeout cooldown");
        assert_eq!(skipped.engine, ENGINE_MB);
        assert!(t_probe.elapsed() < Duration::from_millis(500), "persisted cooldown must skip 3s probe after renew execv");
        clear_probe_timeout_backoff(Some(&data), &slow_pion);

        // 9. New front announcing streams < STREAMS is rejected by spawn_front and counts as 1 failure (not immediate demotion), falling back to MB.
        let low_streams_pion = dir.join("low-streams-pion");
        write_script(
            &low_streams_pion,
            "#!/bin/sh\nprintf '{\"listening\":\"%s\",\"streams\":7}\\n' \"$4\"\nexec cat > /dev/null\n",
            true,
        );
        let good_mb = dir.join("good-mb");
        write_script(
            &good_mb,
            "#!/bin/sh\nprintf '{\"listening\":\"%s\",\"streams\":8}\\n' \"$4\"\nexec cat > /dev/null\n",
            true,
        );
        let low_stamp = PionStamp::of(&low_streams_pion).expect("low stamp");
        let resolved_low = ResolvedProgram {
            engine: ENGINE_PION.to_string(),
            program: low_streams_pion.clone(),
            requested: ENGINE_PION.to_string(),
            source: SelectSource::Default,
            fallback_pion_stamp: None,
        };
        let fallback_front = Front::start_resolved_with(resolved_low, &app, Some(good_mb.as_os_str()), &data)
            .expect("falls back to MB when new Pion announces streams < STREAMS");
        assert_eq!(fallback_front.engine(), ENGINE_MB);
        assert!(!is_default_pion_demoted(&data, Some(&low_stamp)), "single startup failure must count as 1/3, not immediate permanent demotion");
        let entries = read_front_breaker_entries(&data);
        assert_eq!(entries.get(&low_stamp.key()).map(|e| e.exits.len()), Some(1));
        fallback_front.end();

        // 10. R3+R4: Unwritable disk (directory blocking front-pion-demoted.json) still trips in-memory K=3 demotion at exact 300s boundary.
        let ro_data = dir.join("unwritable-data");
        std::fs::create_dir_all(ro_data.join("run/front-pion-demoted.json")).unwrap();
        let ro_t0 = 1_800_000_000_000u64;
        assert!(!record_default_pion_failure_at(&ro_data, &stamp_b, ro_t0));
        assert!(!record_default_pion_failure_at(&ro_data, &stamp_b, ro_t0 + 1_000));
        // Exact 300_000ms boundary (`ts > cutoff` aligned with TS): `ro_t0` expires at `ro_t0 + 300_000` -> still 2 exits.
        assert!(!record_default_pion_failure_at(&ro_data, &stamp_b, ro_t0 + DEFAULT_BREAKER_WINDOW_MS));
        assert!(!is_default_pion_demoted(&ro_data, Some(&stamp_b)));
        // Next exit at `ro_t0 + 300_000` makes 3 exits in window -> demoted in memory!
        assert!(record_default_pion_failure_at(&ro_data, &stamp_b, ro_t0 + DEFAULT_BREAKER_WINDOW_MS));
        assert!(is_default_pion_demoted(&ro_data, Some(&stamp_b)));

        // 11. R4 (Astra P1 #4): Readable stale disk file `[1000_000, 1001_000]` + failing writer on `[2000_000, 2001_000, 2002_000]`
        //     must NOT drop pending in-memory failures and MUST trip demotion on the 3rd failure!
        let stale_data = dir.join("stale-enospc-data");
        std::fs::create_dir_all(stale_data.join("run")).unwrap();
        assert!(!record_default_pion_failure_at(&stale_data, &stamp_b, 1_000_000_000_000));
        assert!(!record_default_pion_failure_at(&stale_data, &stamp_b, 1_000_000_001_000));
        assert!(!record_default_pion_failure_at_with_writer(&stale_data, &stamp_b, 2_000_000_000_000, |_, _| false));
        assert!(!record_default_pion_failure_at_with_writer(&stale_data, &stamp_b, 2_000_000_001_000, |_, _| false));
        assert!(record_default_pion_failure_at_with_writer(&stale_data, &stamp_b, 2_000_000_002_000, |_, _| false));
        assert!(is_default_pion_demoted(&stale_data, Some(&stamp_b)));

        // 12. R3+R4: Wildcard invalid/shadow warn deduplication returns true once per raw value (including non-string JSON).
        assert!(super::should_warn_wildcard_value("shadow-r3-dedup-test"));
        assert!(!super::should_warn_wildcard_value("shadow-r3-dedup-test"));
        assert!(super::should_warn_wildcard_value("42"));
        assert!(!super::should_warn_wildcard_value("42"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
