//! stillfail-station: the native launcher of the TypeScript station (docs/station-ts-native.md §2), with the Rust
//! station's command line (bin/stillfail, the desktop app and the installer call it).
//!
//! `run` is the launcher's own: it holds the data directory's lock, the two listening ports and the pid that
//! run/station.json names, and runs the station's process under it (run.rs), starting a new one beside it on
//! SIGUSR2 and letting the old one go once the new one is ready. Every other command is the station's: exec'd with the
//! same arguments. `station_of(app, data, invocation)` unifies engine selection across `run` and CLI commands
//! (`STILLFAIL_STATION_ENGINE` > `config.json` `"engine"` > default `"node"`), gating `"pion"` behind a cached,
//! bounded `stillfail-station-pion --version` capability probe (`roles:` for `run`, `commands:` per CLI command),
//! with `STILLFAIL_STATION_PION` binary override and `STILLFAIL_STATION_ENGINE_STRICT=1` fail-loud mode.
//! `handoff-version` says 4: a Rust station asked to hand over to this binary does not exec it (it does only
//! for 1); a launcher before this one does, to take its place at a handover (from 3: run.rs `renew`; on Windows from 4:
//! run_windows.rs `renew`).

mod data;
#[cfg_attr(windows, allow(dead_code))]
mod diagnose;
#[cfg(unix)]
mod front;
mod lifecycle;
mod log;
mod ports;
/// The entrances Windows' launcher keeps for Node (built and tested everywhere; run where Node cannot be handed sockets).
#[cfg_attr(unix, allow(dead_code))]
mod proxy;
#[cfg_attr(windows, path = "run_windows.rs")]
mod run;

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::Read;
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant, UNIX_EPOCH};

/// Where Node and the station's script are in the release (`--app`).
#[cfg(unix)]
const NODE_IN_APP: &str = "node/bin/node";
/// Node's own Windows layout: node.exe at the top of its directory.
#[cfg(windows)]
const NODE_IN_APP: &str = "node/node.exe";
const MAIN_IN_APP: &str = "station/main.js";
/// The MoonBit station in the release: the whole station where there is no `MAIN_IN_APP` (and its front either way,
/// front.rs).
#[cfg(unix)]
const READER_IN_APP: &str = "station/stillfail-reader";
#[cfg(windows)]
const READER_IN_APP: &str = "station/stillfail-reader.exe";
/// The Pion full station in the release (`stillfail-station-pion`).
#[cfg(unix)]
const PION_STATION_IN_APP: &str = "station/stillfail-station-pion";
#[cfg(windows)]
const PION_STATION_IN_APP: &str = "station/stillfail-station-pion.exe";
/// Node to run instead of the release's (tests, development).
const NODE_VAR: &str = "STILLFAIL_NODE";
/// Station engine override (`node` | `pion` | `moonbit`).
const STATION_ENGINE_VAR: &str = "STILLFAIL_STATION_ENGINE";
/// Override path to `stillfail-station-pion` binary.
const STATION_PION_VAR: &str = "STILLFAIL_STATION_PION";
/// Strict engine mode (`1` | `true`): fail loudly instead of silently falling back to Node.
const STATION_ENGINE_STRICT_VAR: &str = "STILLFAIL_STATION_ENGINE_STRICT";
/// Bounded timeout for `stillfail-station-pion --version` capability probe.
const PROBE_VERSION_WITHIN: Duration = Duration::from_secs(3);
/// Cooldown after a `--version` probe timeout for the same binary stamp (mirrors `front.rs`).
const PROBE_TIMEOUT_COOLDOWN: Duration = Duration::from_secs(30);
/// Cap on bytes read from `stillfail-station-pion --version`.
const PROBE_STDOUT_LIMIT: usize = 64 * 1024;
/// The handoff this binary reads: none of the Rust station's (which is 1); from 3, a running launcher's (`--resume`) on
/// Unix; from 4 on Windows too (run_windows.rs `renew`: a pipe's name, which a Windows launcher from before cannot read).
const HANDOFF_VERSION: u32 = 4;
/// `run`'s exit when another station runs the data directory (the desktop app reads it: apps/desktop/src/station.ts).
const HELD: i32 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invocation<'a> {
    Run,
    Command(&'a str),
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct StationPionCaps {
    roles: Vec<String>,
    commands: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProbeStamp {
    size: u64,
    mtime_sec: u64,
    mtime_nsec: u32,
    #[cfg(unix)]
    ino: u64,
    #[cfg(unix)]
    ctime_sec: i64,
    #[cfg(unix)]
    ctime_nsec: i64,
    #[cfg(unix)]
    mode: u32,
}

impl ProbeStamp {
    fn of(path: &Path) -> Option<Self> {
        let meta = std::fs::metadata(path).ok()?;
        if !meta.is_file() {
            return None;
        }
        let modified = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
        Some(ProbeStamp {
            size: meta.len(),
            mtime_sec: modified.as_secs(),
            mtime_nsec: modified.subsec_nanos(),
            #[cfg(unix)]
            ino: meta.ino(),
            #[cfg(unix)]
            ctime_sec: meta.ctime(),
            #[cfg(unix)]
            ctime_nsec: meta.ctime_nsec(),
            #[cfg(unix)]
            mode: meta.mode(),
        })
    }
}

#[derive(Clone, Debug)]
enum ProbeError {
    /// Deterministic failure for this exact binary stamp (non-zero exit, oversized output, malformed line).
    Deterministic(String),
    /// Timed out waiting for `--version`; cooled down temporarily, never cached permanently.
    TimedOut(String),
    /// Transient OS error (e.g. EACCES/ETXTBSY/spawn failure); never cached.
    Transient(String),
}

impl ProbeError {
    fn message(&self) -> &str {
        match self {
            ProbeError::Deterministic(m) | ProbeError::TimedOut(m) | ProbeError::Transient(m) => m,
        }
    }
}

#[derive(Clone, Debug)]
enum CachedProbe {
    Ok(StationPionCaps),
    Deterministic(String),
    TimedOut { message: String, retry_after: Instant },
}

type ProbeCacheMap = HashMap<PathBuf, (ProbeStamp, CachedProbe)>;
static STATION_PION_PROBE_CACHE: Mutex<Option<ProbeCacheMap>> = Mutex::new(None);

/// Strictly validates single-line `--version` handshake:
/// `stillfail-station-pion <non-empty-version> roles:<csv> commands:<csv>` (exactly 4 whitespace-separated tokens).
fn parse_station_pion_version(text: &str) -> Option<StationPionCaps> {
    let trimmed = text.trim_end_matches(['\r', '\n']);
    if trimmed.is_empty() || trimmed.contains('\n') || trimmed.contains('\r') {
        return None;
    }
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.len() != 4 {
        return None;
    }
    if parts[0] != "stillfail-station-pion" || parts[1].is_empty() {
        return None;
    }
    let roles_csv = parts[2].strip_prefix("roles:")?;
    let cmds_csv = parts[3].strip_prefix("commands:")?;
    let roles = roles_csv.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect();
    let commands = cmds_csv.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect();
    Some(StationPionCaps { roles, commands })
}

#[cfg(unix)]
fn read_stdout_bounded(mut out: std::process::ChildStdout, deadline: Instant) -> Result<Vec<u8>, ProbeError> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(ProbeError::TimedOut("--version timed out".to_string()));
        }
        let mut pfd = libc::pollfd { fd: out.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: poll on one live pollfd.
        let polled = unsafe { libc::poll(&mut pfd, 1, left.as_millis().min(i32::MAX as u128) as libc::c_int) };
        if polled < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if polled <= 0 {
            return Err(ProbeError::TimedOut("--version timed out".to_string()));
        }
        match out.read(&mut chunk) {
            Ok(0) => return Ok(buf),
            Ok(n) => {
                if buf.len() + n > PROBE_STDOUT_LIMIT {
                    return Err(ProbeError::Deterministic(format!("--version output exceeded {PROBE_STDOUT_LIMIT} bytes")));
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(ProbeError::Transient(format!("read failed: {e}"))),
        }
    }
}

#[cfg(not(unix))]
fn read_stdout_bounded(mut out: std::process::ChildStdout, deadline: Instant) -> Result<Vec<u8>, ProbeError> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 1024];
        loop {
            match out.read(&mut chunk) {
                Ok(0) => {
                    let _ = tx.send(Ok(buf));
                    return;
                }
                Ok(n) => {
                    if buf.len() + n > PROBE_STDOUT_LIMIT {
                        let _ = tx.send(Err(ProbeError::Deterministic(format!("--version output exceeded {PROBE_STDOUT_LIMIT} bytes"))));
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                Err(e) => {
                    let _ = tx.send(Err(ProbeError::Transient(format!("read failed: {e}"))));
                    return;
                }
            }
        }
    });
    let left = deadline.saturating_duration_since(Instant::now());
    match rx.recv_timeout(left) {
        Ok(res) => res,
        Err(_) => Err(ProbeError::TimedOut("--version timed out".to_string())),
    }
}

fn probe_station_pion_uncached(program: &Path, within: Duration) -> Result<StationPionCaps, ProbeError> {
    let mut child = Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| ProbeError::Transient(format!("spawn failed: {e}")))?;
    let Some(out) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ProbeError::Transient("missing stdout pipe".to_string()));
    };
    let deadline = Instant::now() + within;
    let buf = match read_stdout_bounded(out, deadline) {
        Ok(b) => b,
        Err(e) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(e);
        }
    };
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
                return Err(ProbeError::Transient(format!("wait failed: {e}")));
            }
        }
    };
    if !status.success() {
        return Err(ProbeError::Deterministic(format!("--version exited with {status}")));
    }
    let text = String::from_utf8_lossy(&buf);
    parse_station_pion_version(&text)
        .ok_or_else(|| ProbeError::Deterministic(format!("--version invalid handshake ({})", text.trim())))
}

fn probe_station_pion_caps_at(program: &Path, within: Duration, timeout_cooldown: Duration, now: Instant) -> Result<StationPionCaps, String> {
    let Some(stamp) = ProbeStamp::of(program) else {
        return Err("binary does not exist or is not a regular file".to_string());
    };
    {
        let guard = STATION_PION_PROBE_CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(cache) = guard.as_ref()
            && let Some((cached_stamp, cached_entry)) = cache.get(program)
            && *cached_stamp == stamp
        {
            match cached_entry {
                CachedProbe::Ok(caps) => return Ok(caps.clone()),
                CachedProbe::Deterministic(err) => return Err(err.clone()),
                CachedProbe::TimedOut { message, retry_after } if now < *retry_after => return Err(message.clone()),
                CachedProbe::TimedOut { .. } => {}
            }
        }
    }
    match probe_station_pion_uncached(program, within) {
        Ok(caps) => {
            let mut guard = STATION_PION_PROBE_CACHE.lock().unwrap_or_else(|e| e.into_inner());
            guard.get_or_insert_with(HashMap::new).insert(program.to_path_buf(), (stamp, CachedProbe::Ok(caps.clone())));
            Ok(caps)
        }
        Err(ProbeError::Deterministic(msg)) => {
            let mut guard = STATION_PION_PROBE_CACHE.lock().unwrap_or_else(|e| e.into_inner());
            guard.get_or_insert_with(HashMap::new).insert(program.to_path_buf(), (stamp, CachedProbe::Deterministic(msg.clone())));
            Err(msg)
        }
        Err(ProbeError::TimedOut(msg)) => {
            if !timeout_cooldown.is_zero() {
                let mut guard = STATION_PION_PROBE_CACHE.lock().unwrap_or_else(|e| e.into_inner());
                guard.get_or_insert_with(HashMap::new).insert(
                    program.to_path_buf(),
                    (stamp, CachedProbe::TimedOut { message: msg.clone(), retry_after: now + timeout_cooldown }),
                );
            }
            Err(msg)
        }
        Err(err @ ProbeError::Transient(_)) => {
            // Never cache transient errors (EACCES, ETXTBSY, etc.) so chmod +x or retry recovers immediately.
            Err(err.message().to_string())
        }
    }
}

fn is_strict_value(raw: Option<&OsStr>) -> bool {
    raw.and_then(OsStr::to_str)
        .map(|s| s.trim().to_ascii_lowercase())
        .is_some_and(|s| s == "1" || s == "true")
}

pub fn node(app: &Path) -> PathBuf {
    std::env::var_os(NODE_VAR).filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| app.join(NODE_IN_APP))
}

pub fn main_js(app: &Path) -> PathBuf {
    app.join(MAIN_IN_APP)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StationEngine {
    Node,
    Pion,
    MoonBit,
}

/// What runs the station of the release at `app`: its program, engine kind, and (for Node) the script it is given first.
#[derive(Debug, PartialEq, Eq)]
pub struct Station {
    pub program: PathBuf,
    pub script: Option<PathBuf>,
    pub engine: StationEngine,
}

impl Station {
    /// The command that runs it, the station's own arguments to follow.
    pub fn command(&self) -> std::process::Command {
        let mut command = std::process::Command::new(&self.program);
        if let Some(script) = &self.script {
            command.arg(script);
        }
        command
    }

    /// Short engine label for lifecycle logs (`"Node"`, `"Pion"`, `"MoonBit"`).
    pub fn engine_label(&self) -> &'static str {
        match self.engine {
            StationEngine::Node => "Node",
            StationEngine::Pion => "Pion",
            StationEngine::MoonBit => "MoonBit",
        }
    }
}

/// Unified station engine, role, and per-command resolver for `run` and CLI subcommands.
/// Priority: `STILLFAIL_STATION_ENGINE` > `config.json` `"engine"` > default `"node"`.
pub fn station_of(app: &Path, data: &Path, invocation: Invocation<'_>) -> Result<Station, String> {
    let env_engine = std::env::var_os(STATION_ENGINE_VAR);
    let env_pion = std::env::var_os(STATION_PION_VAR);
    let env_strict = std::env::var_os(STATION_ENGINE_STRICT_VAR);
    station_of_with_now(
        app,
        data,
        invocation,
        env_engine.as_deref(),
        env_pion.as_deref(),
        is_strict_value(env_strict.as_deref()),
        PROBE_VERSION_WITHIN,
        PROBE_TIMEOUT_COOLDOWN,
        Instant::now(),
    )
}

#[allow(clippy::too_many_arguments)]
fn station_of_with_now(
    app: &Path,
    data: &Path,
    invocation: Invocation<'_>,
    env_engine: Option<&OsStr>,
    env_pion: Option<&OsStr>,
    strict: bool,
    probe_within: Duration,
    timeout_cooldown: Duration,
    now: Instant,
) -> Result<Station, String> {
    let env_choice = env_engine
        .and_then(OsStr::to_str)
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty());

    let requested = if let Some(engine) = env_choice {
        engine
    } else {
        match data::read_engine(data) {
            Ok(Some(engine)) => engine,
            Ok(None) => "node".to_string(),
            Err(err) => {
                if strict {
                    return Err(format!("could not read engine from config.json: {err}"));
                }
                log::warn(&format!("could not read engine from config.json ({err}); falling back to Node"));
                "node".to_string()
            }
        }
    };

    let script = main_js(app);
    match requested.as_str() {
        "node" => Ok(station(app)),
        "moonbit" => {
            if script.is_file() {
                log::info(r#"config.json sets "engine": "moonbit", which is retired; starting Node instead"#);
                return Ok(Station { program: node(app), script: Some(script), engine: StationEngine::Node });
            }
            let reader = app.join(READER_IN_APP);
            if reader.is_file() {
                return Ok(Station { program: reader, script: None, engine: StationEngine::MoonBit });
            }
            Ok(station(app))
        }
        "pion" => {
            let pion_path = env_pion
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| app.join(PION_STATION_IN_APP));
            let caps = match probe_station_pion_caps_at(&pion_path, probe_within, timeout_cooldown, now) {
                Ok(caps) => caps,
                Err(err) => {
                    let reason = format!("stillfail-station-pion ({}) is not usable: {err}", pion_path.display());
                    if strict {
                        return Err(reason);
                    }
                    log::warn(&format!("{reason}; falling back to Node"));
                    return Ok(station(app));
                }
            };
            match invocation {
                Invocation::Run => {
                    let role = if data::is_rig(data) { "rig" } else { "whole" };
                    if caps.roles.iter().any(|r| r == role) {
                        Ok(Station { program: pion_path, script: None, engine: StationEngine::Pion })
                    } else {
                        let reason = format!(
                            "stillfail-station-pion ({}) does not advertise required role '{role}' (roles: {})",
                            pion_path.display(),
                            caps.roles.join(",")
                        );
                        if strict {
                            Err(reason)
                        } else {
                            log::warn(&format!("{reason}; falling back to Node"));
                            Ok(station(app))
                        }
                    }
                }
                Invocation::Command(cmd) => {
                    if caps.commands.iter().any(|c| c == cmd) {
                        Ok(Station { program: pion_path, script: None, engine: StationEngine::Pion })
                    } else {
                        let reason = format!(
                            "stillfail-station-pion ({}) does not advertise command '{cmd}' (commands: {})",
                            pion_path.display(),
                            caps.commands.join(",")
                        );
                        if strict {
                            Err(reason)
                        } else {
                            log::warn(&format!("{reason}; falling back to Node"));
                            Ok(station(app))
                        }
                    }
                }
            }
        }
        other => {
            let reason = format!("unknown station engine '{other}'");
            if strict {
                Err(reason)
            } else {
                log::warn(&format!("{reason}; falling back to Node"));
                Ok(station(app))
            }
        }
    }
}

/// The MoonBit station where the release has it and no Node script; else Node and the script (a release from
/// before the MoonBit station, rolled back to, and the tests' stand-in), which needs Node in the release.
pub fn station(app: &Path) -> Station {
    let script = main_js(app);
    let reader = app.join(READER_IN_APP);
    if !script.is_file() && reader.is_file() {
        Station { program: reader, script: None, engine: StationEngine::MoonBit }
    } else {
        Station { program: node(app), script: Some(script), engine: StationEngine::Node }
    }
}

fn usage() -> ! {
    eprintln!("usage:\n  stillfail-station run --app DIR [--port N] [--data DIR] [--with-parent]\n  stillfail-station enroll <cloud-origin> <token> [--data DIR]\n  stillfail-station status [--data DIR]\n  stillfail-station id [--data DIR]\n  stillfail-station lock status|reset [--data DIR]\n  stillfail-station channel [stable|beta] [--app DIR] [--data DIR]\n  stillfail-station update [--beta|--stable] [--app DIR] [--data DIR]\n  stillfail-station heap [--data DIR]\n  stillfail-station handoff-version\n\n--data: default ~/.stillfail ($STILLFAIL_DATA).\nrun: --app is the release; --port the loopback port's (default 4760, a free one when it is taken); --with-parent: end when the parent does.\n${NODE_VAR}: the Node to run instead of <app>/{NODE_IN_APP}, for a release with {MAIN_IN_APP}.");
    std::process::exit(2);
}

fn main() {
    let given: Vec<OsString> = std::env::args_os().skip(1).collect();
    let mut args: Vec<String> = given.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    let mut take = |flag: &str| -> Option<String> {
        let i = args.iter().position(|a| a == flag)?;
        let value = args.get(i + 1).cloned();
        args.drain(i..(i + 2).min(args.len()));
        value
    };
    let data = take("--data");
    let app = take("--app");
    // What the Node part ran on, from launchers written before it went (older desktop apps): taken and let be.
    let _ = take("--node");
    let port = take("--port");
    let handoff = take("--handoff");
    let resume = take("--resume");
    let with_parent = args.iter().position(|a| a == "--with-parent").map(|i| args.remove(i)).is_some();
    match args.first().map(String::as_str) {
        Some("run") => {
            let Some(app) = app else { usage() };
            let named = port.is_some();
            let port = match port.map(|p| p.parse::<u16>()).transpose() {
                Ok(port) => port.unwrap_or(4760),
                Err(error) => {
                    eprintln!("--port: {error}");
                    std::process::exit(1);
                }
            };
            // A Rust station's handoff (its descriptors) is never ours to take: it asks handoff-version first.
            if let Some(file) = handoff {
                log::warn(&format!("a handoff file was given ({file}); this launcher reads none, starting afresh"));
                let _ = std::fs::remove_file(file);
            }
            let data = data::data_dir(&data::home(), data.or_else(|| data::var("DATA")).map(PathBuf::from));
            std::process::exit(run::run(run::Options { data, app: PathBuf::from(app), port, named, with_parent, resume }));
        }
        Some("handoff-version") => println!("{HANDOFF_VERSION}"),
        Some(cmd @ ("enroll" | "status" | "id" | "channel" | "update" | "lock" | "heap")) => {
            let app = app.map(PathBuf::from).or_else(app_of_this_binary).unwrap_or_else(|| {
                eprintln!("the release this binary belongs to (with {PION_STATION_IN_APP}, {READER_IN_APP} or {MAIN_IN_APP}) was not found; give it as --app DIR");
                std::process::exit(1);
            });
            let data = data::data_dir(&data::home(), data.or_else(|| data::var("DATA")).map(PathBuf::from));
            let station = match station_of(&app, &data, Invocation::Command(cmd)) {
                Ok(station) => station,
                Err(error) => {
                    eprintln!("stillfail-station: {error}");
                    std::process::exit(1);
                }
            };
            let mut command = station.command();
            command.args(&given);
            #[cfg(unix)]
            let error = command.exec();
            // No exec on Windows: the station runs as a child, its code this process's.
            #[cfg(windows)]
            let error = match command.status() {
                Ok(status) => std::process::exit(status.code().unwrap_or(1)),
                Err(error) => error,
            };
            eprintln!("{} did not run: {error}", station.program.display());
            std::process::exit(1);
        }
        _ => usage(),
    }
}

/// The release this binary is in, when not given (`stillfail status` gives none): the nearest directory above it that
/// has the station (Pion station, MoonBit reader, or Node's script).
fn app_of_this_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    app_above(&exe)
}

fn app_above(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .skip(1)
        .find(|dir| main_js(dir).is_file() || dir.join(READER_IN_APP).is_file() || dir.join(PION_STATION_IN_APP).is_file())
        .map(Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_SEQ: AtomicU64 = AtomicU64::new(0);
    const HEX32: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn temp_dir(tag: &str) -> PathBuf {
        let n = TEST_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("launcher-main-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("station")).unwrap();
        std::fs::create_dir_all(dir.join("data")).unwrap();
        dir
    }

    #[cfg(unix)]
    fn write_fake_pion(path: &Path, version_output: &str) {
        use std::os::unix::fs::PermissionsExt;
        let script = format!("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n  printf '%s\\n' '{version_output}'\n  exit 0\nfi\nexit 2\n");
        std::fs::write(path, script).unwrap();
        let mut perms = std::fs::metadata(path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).unwrap();
    }

    #[allow(clippy::too_many_arguments)]
    fn station_of_with(
        app: &Path,
        data: &Path,
        invocation: Invocation<'_>,
        env_engine: Option<&OsStr>,
        env_pion: Option<&OsStr>,
        strict: bool,
        probe_within: Duration,
        timeout_cooldown: Duration,
    ) -> Result<Station, String> {
        station_of_with_now(app, data, invocation, env_engine, env_pion, strict, probe_within, timeout_cooldown, Instant::now())
    }

    #[test]
    fn the_release_is_found_above_the_binary() {
        let dir = temp_dir("app-node");
        std::fs::create_dir_all(dir.join("mesh/target/release")).unwrap();
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        assert_eq!(app_above(&dir.join("mesh/target/release/stillfail-station")), Some(dir.clone()));
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(app_above(Path::new("/nowhere/at/all/x")), None);
    }

    #[test]
    fn a_release_with_only_pion_station_is_discovered_by_app_above() {
        let dir = temp_dir("app-pion");
        std::fs::create_dir_all(dir.join("mesh/target/release")).unwrap();
        std::fs::write(dir.join(PION_STATION_IN_APP), "").unwrap();
        assert_eq!(app_above(&dir.join("mesh/target/release/stillfail-station")), Some(dir.clone()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_release_with_the_moonbit_station_alone_is_found_and_runs_it() {
        let dir = temp_dir("app-mb");
        std::fs::create_dir_all(dir.join("mesh/target/release")).unwrap();
        std::fs::write(dir.join(READER_IN_APP), "").unwrap();
        assert_eq!(app_above(&dir.join("mesh/target/release/stillfail-station")), Some(dir.clone()));
        let st = station(&dir);
        assert_eq!((st.program, st.script), (dir.join(READER_IN_APP), None));
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let st = station(&dir);
        assert_eq!(st.script, Some(dir.join("station/main.js")));
        assert_ne!(st.program, dir.join(READER_IN_APP));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_station_with_retired_moonbit_engine_starts_node_when_main_js_exists() {
        let dir = temp_dir("retired-mb");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        std::fs::write(dir.join(READER_IN_APP), "").unwrap();
        assert_eq!(
            station_of_with(&dir, &data, Invocation::Run, None, None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap().script,
            Some(dir.join("station/main.js"))
        );
        std::fs::write(data.join("config.json"), r#"{"engine":"moonbit"}"#).unwrap();
        assert_eq!(
            station_of_with(&dir, &data, Invocation::Run, None, None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap().script,
            Some(dir.join("station/main.js"))
        );
        // Even in strict mode, retired "engine": "moonbit" preserves Node cutover semantics.
        assert_eq!(
            station_of_with(&dir, &data, Invocation::Run, None, None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap().script,
            Some(dir.join("station/main.js"))
        );
        std::fs::remove_file(dir.join("station/main.js")).unwrap();
        let st = station_of_with(&dir, &data, Invocation::Run, None, None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!((st.program, st.script), (dir.join(READER_IN_APP), None));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parse_station_pion_version_enforces_strict_four_token_single_line() {
        let empty = parse_station_pion_version("stillfail-station-pion 0.1.0 roles: commands:\n").unwrap();
        assert!(empty.roles.is_empty());
        assert!(empty.commands.is_empty());

        let populated = parse_station_pion_version("stillfail-station-pion 0.1.0 roles:rig,whole commands:channel,status,id").unwrap();
        assert_eq!(populated.roles, vec!["rig", "whole"]);
        assert_eq!(populated.commands, vec!["channel", "status", "id"]);

        // Reject wrong binary name, missing fields, extra tokens, or multi-line output.
        assert!(parse_station_pion_version("other-program commands:status").is_none());
        assert!(parse_station_pion_version("other-program 0.1.0 roles:rig commands:status").is_none());
        assert!(parse_station_pion_version("stillfail-station-pion 0.1.0 roles:rig").is_none());
        assert!(parse_station_pion_version("stillfail-station-pion 0.1.0 commands:channel").is_none());
        assert!(parse_station_pion_version("stillfail-station-pion 0.1.0 roles:rig commands:channel extra").is_none());
        assert!(parse_station_pion_version("stillfail-station-pion 0.1.0 roles:rig commands:channel\nsecond line").is_none());
        assert!(parse_station_pion_version("stillfail-pion 0.1.0 modes:mesh").is_none());
    }

    #[test]
    fn corrupt_config_errors_in_strict_mode_and_falls_back_in_prod() {
        let dir = temp_dir("corrupt-cfg");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        std::fs::write(data.join("config.json"), "{not valid json").unwrap();

        // Strict mode refuses to silently fall back to Node.
        let err = station_of_with(&dir, &data, Invocation::Command("status"), None, None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap_err();
        assert!(err.contains("could not read engine from config.json"), "unexpected err: {err}");

        // Non-string engine also errors in strict mode.
        std::fs::write(data.join("config.json"), r#"{"engine":123}"#).unwrap();
        let err = station_of_with(&dir, &data, Invocation::Command("status"), None, None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap_err();
        assert!(err.contains("engine must be a string"), "unexpected err: {err}");

        // Non-strict mode warns and falls back to Node.
        let st = station_of_with(&dir, &data, Invocation::Command("status"), None, None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!(st.script, Some(dir.join("station/main.js")));

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn priority_matrix_env_over_config_over_default() {
        let dir = temp_dir("priority");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let pion = dir.join(PION_STATION_IN_APP);
        write_fake_pion(&pion, "stillfail-station-pion 0.1.0 roles:whole commands:channel");

        // Default is Node even when pion binary exists.
        let st = station_of_with(&dir, &data, Invocation::Command("channel"), None, None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!(st.script, Some(dir.join("station/main.js")));
        assert_eq!(st.engine_label(), "Node");

        // config.json "engine": "pion" selects Pion when command is advertised.
        std::fs::write(data.join("config.json"), r#"{"engine":"pion"}"#).unwrap();
        let st = station_of_with(&dir, &data, Invocation::Command("channel"), None, None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!((st.program.clone(), st.script.clone()), (pion.clone(), None));
        assert_eq!(st.engine_label(), "Pion");

        // Env "node" overrides config "pion".
        let st = station_of_with(&dir, &data, Invocation::Command("channel"), Some(OsStr::new("node")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!(st.script, Some(dir.join("station/main.js")));

        // Env "pion" overrides config "node".
        std::fs::write(data.join("config.json"), r#"{"engine":"node"}"#).unwrap();
        let st = station_of_with(&dir, &data, Invocation::Command("channel"), Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!((st.program, st.script), (pion, None));

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn commands_gating_allows_listed_and_rejects_unlisted_in_strict_and_prod() {
        let dir = temp_dir("commands-gate");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let pion = dir.join(PION_STATION_IN_APP);
        write_fake_pion(&pion, "stillfail-station-pion 0.1.0 roles: commands:channel");

        // Advertised command runs Pion.
        let st = station_of_with(&dir, &data, Invocation::Command("channel"), Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!((st.program, st.script), (pion, None));

        // Unlisted command falls back to Node in prod mode.
        let st = station_of_with(&dir, &data, Invocation::Command("status"), Some(OsStr::new("pion")), None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!(st.script, Some(dir.join("station/main.js")));

        // Unlisted command errors loudly in strict mode.
        let err = station_of_with(&dir, &data, Invocation::Command("status"), Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap_err();
        assert!(err.contains("does not advertise command 'status'"), "unexpected err: {err}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn roles_rig_accepts_rig_and_rejects_whole_or_mixed() {
        let dir = temp_dir("roles-rig");
        let data = dir.join("data");
        std::fs::create_dir_all(data.join("mesh")).unwrap();
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let pion = dir.join(PION_STATION_IN_APP);
        write_fake_pion(&pion, "stillfail-station-pion 0.1.0 roles:rig commands:");

        // 1. Pure rig data dir (valid 64-hex person) -> Pion selected.
        std::fs::write(
            data.join("mesh/cloud.json"),
            format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{HEX32}"}}}}"#),
        )
        .unwrap();
        let st = station_of_with(&dir, &data, Invocation::Run, Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!((st.program, st.script), (pion.clone(), None));

        // 2. Whole station -> fallback in prod, error in strict.
        std::fs::write(data.join("mesh/cloud.json"), r#"{"workspace":"ws-1"}"#).unwrap();
        let st = station_of_with(&dir, &data, Invocation::Run, Some(OsStr::new("pion")), None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!(st.script, Some(dir.join("station/main.js")));
        let err = station_of_with(&dir, &data, Invocation::Run, Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap_err();
        assert!(err.contains("required role 'whole'"), "unexpected err: {err}");

        // 3. Mixed (home rig + joined full workspace) -> treated as whole -> fallback in prod, error in strict.
        std::fs::write(
            data.join("mesh/cloud.json"),
            format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{HEX32}"}},"joined":[{{"workspace":"ws-2"}}]}}"#),
        )
        .unwrap();
        let st = station_of_with(&dir, &data, Invocation::Run, Some(OsStr::new("pion")), None, false, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!(st.script, Some(dir.join("station/main.js")));
        let err = station_of_with(&dir, &data, Invocation::Run, Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap_err();
        assert!(err.contains("required role 'whole'"), "unexpected err: {err}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn chmod_plus_x_invalidates_probe_and_transient_spawn_error_is_not_cached() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("chmod-recover");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();

        let bin = dir.join("recoverable-station-pion");
        std::fs::write(&bin, "#!/bin/sh\necho 'stillfail-station-pion 0.1.0 roles:whole commands:channel'\n").unwrap();
        // Initially non-executable (0644) -> fails with EACCES (transient, not cached).
        let err = station_of_with(&dir, &data, Invocation::Command("channel"), Some(OsStr::new("pion")), Some(bin.as_os_str()), true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap_err();
        assert!(err.contains("is not usable"), "unexpected err: {err}");

        // chmod +x without changing size or mtime -> immediately succeeds in same process!
        let mut perms = std::fs::metadata(&bin).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&bin, perms).unwrap();
        let st = station_of_with(&dir, &data, Invocation::Command("channel"), Some(OsStr::new("pion")), Some(bin.as_os_str()), true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        assert_eq!((st.program, st.script), (bin, None));

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn timeout_is_cooled_down_temporarily_and_not_permanently_locked() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("timeout-cooldown");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let flag = dir.join("already-slept");
        let bin = dir.join("candidate");
        // First invocation sleeps past the 50ms probe timeout; second succeeds immediately.
        let script = format!(
            "#!/bin/sh\nif [ ! -f '{}' ]; then\n  : > '{}'\n  sleep 1\nfi\necho 'stillfail-station-pion 0.1.0 roles:whole commands:channel'\n",
            flag.display(),
            flag.display()
        );
        std::fs::write(&bin, script).unwrap();
        let mut perms = std::fs::metadata(&bin).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&bin, perms).unwrap();

        let t0 = Instant::now();
        let err = station_of_with_now(
            &dir,
            &data,
            Invocation::Command("channel"),
            Some(OsStr::new("pion")),
            Some(bin.as_os_str()),
            true,
            Duration::from_millis(50),
            PROBE_TIMEOUT_COOLDOWN,
            t0,
        )
        .unwrap_err();
        assert!(err.contains("timed out"), "unexpected err: {err}");

        // Still within cooldown -> cached timeout error returned without re-running binary.
        let still_cooled = station_of_with_now(
            &dir,
            &data,
            Invocation::Command("channel"),
            Some(OsStr::new("pion")),
            Some(bin.as_os_str()),
            true,
            Duration::from_secs(2),
            PROBE_TIMEOUT_COOLDOWN,
            t0 + Duration::from_secs(5),
        )
        .unwrap_err();
        assert!(still_cooled.contains("timed out"), "unexpected err during cooldown: {still_cooled}");

        // Advance virtual `now` past PROBE_TIMEOUT_COOLDOWN (zero std::thread::sleep!) -> re-probes and succeeds,
        // and engine_label() reports "Pion" even though filename is "candidate".
        let st = station_of_with_now(
            &dir,
            &data,
            Invocation::Command("channel"),
            Some(OsStr::new("pion")),
            Some(bin.as_os_str()),
            true,
            Duration::from_secs(2),
            PROBE_TIMEOUT_COOLDOWN,
            t0 + PROBE_TIMEOUT_COOLDOWN,
        )
        .unwrap();
        assert_eq!((st.program.clone(), st.script.clone()), (bin, None));
        assert_eq!(st.engine_label(), "Pion");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn probe_cache_reuses_result_for_same_stamp() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("probe-cache");
        let data = dir.join("data");
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        let count_file = dir.join("probe-count");
        let pion = dir.join(PION_STATION_IN_APP);
        let script = format!(
            "#!/bin/sh\necho 1 >> '{}'\necho 'stillfail-station-pion 0.1.0 roles:whole commands:channel'\n",
            count_file.display()
        );
        std::fs::write(&pion, script).unwrap();
        let mut perms = std::fs::metadata(&pion).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&pion, perms).unwrap();

        let _ = station_of_with(&dir, &data, Invocation::Command("channel"), Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        let _ = station_of_with(&dir, &data, Invocation::Run, Some(OsStr::new("pion")), None, true, PROBE_VERSION_WITHIN, PROBE_TIMEOUT_COOLDOWN).unwrap();
        let probes = std::fs::read_to_string(&count_file).unwrap().lines().count();
        assert_eq!(probes, 1, "unchanged binary stamp must only invoke --version once");

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
