//! The data directory and what the launcher keeps in it, as the Rust station did (mesh/app/src/former.rs,
//! mesh/station/src/main.rs): where it is, its lock, run/station.json, and what config.json says the launcher needs (the
//! MCP endpoint's port, the station's language).

use std::fs::{File, OpenOptions};
#[cfg(unix)]
use std::io::Error;
use std::io::{ErrorKind, Result};
#[cfg(unix)]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// The data directory under the home.
const DATA_DIR: &str = ".stillfail";

/// `name` (without its prefix, as "DATA") from the environment: STILLFAIL_<name>. Empty is unset.
pub fn var(name: &str) -> Option<String> {
    std::env::var(format!("STILLFAIL_{name}")).ok().filter(|v| !v.is_empty())
}

pub fn home() -> PathBuf {
    let home = std::env::var_os("HOME");
    // Windows names it USERPROFILE.
    #[cfg(windows)]
    let home = home.or_else(|| std::env::var_os("USERPROFILE"));
    home.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// The data directory: `given` (--data, or the variable), else ~/.stillfail.
pub fn data_dir(home: &Path, given: Option<PathBuf>) -> PathBuf {
    given.unwrap_or_else(|| home.join(DATA_DIR))
}

/// Whether `data` is the machine's own data directory (~/.stillfail). Only its station
/// takes the usual ports: one on another directory (a test's, a development station's) takes free ones, so it never
/// keeps the machine's station off them.
pub fn is_default(home: &Path, data: &Path) -> bool {
    // Windows' paths are the same whatever their case (a drive letter given as c: or C:).
    #[cfg(windows)]
    let same = |a: &Path, b: &Path| a.to_string_lossy().trim_end_matches(['\\', '/']).eq_ignore_ascii_case(b.to_string_lossy().trim_end_matches(['\\', '/']));
    #[cfg(not(windows))]
    let same = |a: &Path, b: &Path| a.components().eq(b.components());
    same(&home.join(DATA_DIR), data)
}

/// Holds `path` locked for as long as the file lives; None when another process holds it. The descriptor is
/// close-on-exec: the lock is the launcher's alone, not Node's.
pub fn lock(path: &Path) -> Result<Option<File>> {
    let file = OpenOptions::new().create(true).truncate(false).write(true).open(path)?;
    // Windows: the file's own lock (LockFileEx); handles are not inherited unless asked, so it stays the launcher's.
    #[cfg(windows)]
    return match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(std::fs::TryLockError::WouldBlock) => Ok(None),
        Err(std::fs::TryLockError::Error(error)) => Err(error),
    };
    #[cfg(unix)]
    {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = Error::last_os_error();
            return if error.kind() == ErrorKind::WouldBlock { Ok(None) } else { Err(error) };
        }
        Ok(Some(file))
    }
}

/// Writes `text` to `path` whole (a reader never sees half of it).
pub fn write_whole(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
}

/// run/station.json's line, its fields in the Rust station's order (the installer reads it with sed). `handoff` stays 1:
/// the installer takes any for "SIGUSR2 hands over".
/// `renewed_from`: the launcher whose place this one took (Windows' renew), the pid the installer handed over through.
pub fn station_json(pid: u32, started_at: u64, version: &str, renewed_from: Option<u32>) -> String {
    let from = renewed_from.map(|p| format!(",\"renewedFrom\":{p}")).unwrap_or_default();
    format!("{{\"pid\":{pid},\"startedAt\":{started_at},\"version\":{},{FLAGS}{from}}}\n", Value::from(version))
}

/// What the launcher takes: a handover, a drain, the channel asked again. On Unix as signals (SIGUSR2, SIGUSR1, SIGHUP);
/// on Windows, which has none, as lines on its own pipe (run_windows.rs `control_pipe`).
#[cfg(windows)]
const FLAGS: &str = "\"handoff\":1,\"drain\":1,\"channel\":1";
/// Unix's also says it becomes the release's launcher at a handover (`renew`, run.rs): an installer hands over to a new
/// release only through one that does, else what is changed in the launcher never comes (cloud/src/install.ts).
#[cfg(unix)]
const FLAGS: &str = "\"handoff\":1,\"drain\":1,\"channel\":1,\"renew\":1";

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// What the launcher reads of config.json ($STILLFAIL_CONFIG, else <data>/config.json).
#[derive(Debug, PartialEq)]
pub struct Config {
    /// The MCP endpoint's port; `named` when the config sets the port (then taken is an error). It is on 127.0.0.1
    /// whatever the config says (an `http.host` of before is not read): a station has no way in from outside but the
    /// mesh (AGENTS.md).
    pub port: u16,
    pub named: bool,
    pub english: bool,
    /// Legacy `"engine": "moonbit"` flag in config.json (retired; `crate::station_of` logs and starts Node
    /// directly whenever `station/main.js` is present, falling back to `stillfail-reader` only on Node-less
    /// rollback releases or harness test layouts).
    pub moonbit: bool,
}

impl Config {
    /// None for a config that is not there; an error for one that does not read.
    pub fn read(data: &Path) -> std::result::Result<Config, String> {
        let path = var("CONFIG").map(PathBuf::from).unwrap_or_else(|| data.join("config.json"));
        let raw: Value = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))?,
            Err(e) if e.kind() == ErrorKind::NotFound => Value::Null,
            Err(e) => return Err(format!("{}: {e}", path.display())),
        };
        Config::of(&raw).map_err(|e| format!("{}: {e}", path.display()))
    }

    fn of(raw: &Value) -> std::result::Result<Config, String> {
        let http = &raw["http"];
        let port = match &http["port"] {
            Value::Null => None,
            v => Some(v.as_u64().and_then(|p| u16::try_from(p).ok()).ok_or_else(|| format!("http.port: not a port: {v}"))?),
        };
        // As client/i18n's Lang::from_locale: none, empty or zh… is Chinese, anything else English.
        let english = raw["language"].as_str().map(|l| l.trim().to_ascii_lowercase()).is_some_and(|l| !l.is_empty() && !l.starts_with("zh"));
        let moonbit = raw["engine"].as_str() == Some("moonbit");
        Ok(Config { port: port.unwrap_or(4750), named: port.is_some(), english, moonbit })
    }
}

fn json_type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// Reads the optional `"engine"` string (`"node"`, `"pion"`, `"moonbit"`, ...) from `$STILLFAIL_CONFIG` or
/// `<data>/config.json`, trimmed and lowercased.
/// Returns `Ok(None)` ONLY when the file does not exist or the top-level JSON object omits the `"engine"` key.
/// Returns `Err(...)` (naming only path, field, and JSON type — never echoing config contents) on I/O errors,
/// malformed JSON, non-object top-level JSON (e.g. `[]`, `123`), or explicit `"engine": null`/empty/non-string values.
pub fn read_engine(data: &Path) -> std::result::Result<Option<String>, String> {
    let path = var("CONFIG").map(PathBuf::from).unwrap_or_else(|| data.join("config.json"));
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let raw: Value = serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    let Some(obj) = raw.as_object() else {
        return Err(format!("{}: config must be a JSON object, got {}", path.display(), json_type_name(&raw)));
    };
    match obj.get("engine") {
        None => Ok(None),
        Some(Value::String(s)) => {
            let trimmed = s.trim().to_ascii_lowercase();
            if trimmed.is_empty() {
                Err(format!("{}: engine must be a non-empty string", path.display()))
            } else {
                Ok(Some(trimmed))
            }
        }
        Some(other) => Err(format!("{}: engine must be a string, got {}", path.display(), json_type_name(other))),
    }
}

fn is_hex32(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Validates a `RigSelf` object 1:1 with `station/src/cloud/state.ts` `rigSelfOf`:
/// non-empty string `owner` and 64-char lowercase hex `person`.
fn rig_self_valid(raw: Option<&Value>) -> bool {
    let Some(Value::Object(obj)) = raw else { return false };
    let owner_ok = obj.get("owner").and_then(Value::as_str).is_some_and(|s| !s.is_empty());
    let person_ok = obj.get("person").and_then(Value::as_str).is_some_and(is_hex32);
    owner_ok && person_ok
}

/// Whether this machine is rig-only now (enrolled in at least one workspace, `removed_at` key absent,
/// home workspace has a valid `RigSelf`, and every valid entry in `joined` has a valid `RigSelf`).
/// Matches `station/src/cloud/state.ts` (`readState`/`rigSelfOf`/`joinedOf`) + `station/src/cli.ts` `isRig` 1:1.
pub fn is_rig(data: &Path) -> bool {
    let path = data.join("mesh").join("cloud.json");
    let Ok(bytes) = std::fs::read(&path) else { return false };
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(&bytes) else { return false };
    let enrolled = obj.get("workspace").and_then(Value::as_str).is_some_and(|s| !s.is_empty());
    // In JS, `state.removed_at === undefined` is false when `"removed_at": null` is present.
    let not_removed = !obj.contains_key("removed_at");
    let home_rig = rig_self_valid(obj.get("rig"));
    let joined_rig = match obj.get("joined") {
        Some(Value::Array(items)) => items
            .iter()
            .filter(|j| j.as_object().and_then(|o| o.get("workspace")).and_then(Value::as_str).is_some_and(|s| !s.is_empty()))
            .all(|j| rig_self_valid(j.get("rig"))),
        _ => true,
    };
    enrolled && not_removed && home_rig && joined_rig
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("launcher-data-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_data_directory_is_the_one_given_else_stillfail() {
        let home = temp("home");
        assert_eq!(data_dir(&home, Some("/elsewhere".into())), PathBuf::from("/elsewhere"));
        assert_eq!(data_dir(&home, None), home.join(".stillfail"));
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn only_the_home_data_directory_is_the_default() {
        let home = PathBuf::from("/home/u");
        assert!(is_default(&home, &home.join(".stillfail")));
        assert!(!is_default(&home, &PathBuf::from("/tmp/scratchpad/inst")));
        assert!(!is_default(&home, &home.join(".stillfail-dev")));
    }

    #[test]
    fn the_config_names_the_mcp_port_or_leaves_the_usual_one() {
        let of = |s: &str| Config::of(&serde_json::from_str(s).unwrap());
        assert_eq!(of("null").unwrap(), Config { port: 4750, named: false, english: false, moonbit: false });
        assert_eq!(
            of(r#"{"http":{"host":"0.0.0.0","port":5000},"language":"en-US"}"#).unwrap(),
            Config { port: 5000, named: true, english: true, moonbit: false }
        );
        // (the MoonBit station alone, this station's switch: only its own word turns it on)
        assert!(of(r#"{"engine":"moonbit"}"#).unwrap().moonbit);
        assert!(!of(r#"{"engine":"node"}"#).unwrap().moonbit);
        assert!(!of(r#"{"engine":true}"#).unwrap().moonbit);
        assert!(!of(r#"{"language":"zh-CN"}"#).unwrap().english);
        assert!(of(r#"{"http":{"port":70000}}"#).is_err());

        let dir = temp("read-engine");
        assert_eq!(read_engine(&dir), Ok(None));
        std::fs::write(dir.join("config.json"), r#"{}"#).unwrap();
        assert_eq!(read_engine(&dir), Ok(None));
        std::fs::write(dir.join("config.json"), r#"{"engine":" PION "}"#).unwrap();
        assert_eq!(read_engine(&dir), Ok(Some("pion".to_string())));
        std::fs::write(dir.join("config.json"), r#"{"engine":""}"#).unwrap();
        assert!(read_engine(&dir).is_err());
        std::fs::write(dir.join("config.json"), r#"{"engine":"   "}"#).unwrap();
        assert!(read_engine(&dir).is_err());
        std::fs::write(dir.join("config.json"), r#"{"engine":null}"#).unwrap();
        assert!(read_engine(&dir).is_err());
        std::fs::write(dir.join("config.json"), r#"{"engine":["sentinel-engine-val"]}"#).unwrap();
        let err = read_engine(&dir).unwrap_err();
        assert!(err.contains("got array"), "unexpected err: {err}");
        assert!(!err.contains("sentinel-engine-val"), "error must not echo config contents: {err}");
        std::fs::write(dir.join("config.json"), r#"["sentinel-root-val"]"#).unwrap();
        let err = read_engine(&dir).unwrap_err();
        assert!(err.contains("got array"), "unexpected err: {err}");
        assert!(!err.contains("sentinel-root-val"), "error must not echo config contents: {err}");
        std::fs::write(dir.join("config.json"), "{broken json").unwrap();
        assert!(read_engine(&dir).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn is_rig_matches_station_cli_semantics() {
        let dir = temp("is-rig");
        assert!(!is_rig(&dir));
        let mesh = dir.join("mesh");
        std::fs::create_dir_all(&mesh).unwrap();
        let write = |s: &str| std::fs::write(mesh.join("cloud.json"), s).unwrap();
        let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        // Whole station (no rig)
        write(r#"{"workspace":"ws-1"}"#);
        assert!(!is_rig(&dir));
        // Invalid rig missing person (HEX32) is NOT a valid rig
        write(r#"{"workspace":"ws-1","rig":{"owner":"u1"}}"#);
        assert!(!is_rig(&dir));
        // Invalid rig with uppercase hex person is NOT a valid rig
        write(&format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{}"}}}}"#, hex.to_uppercase()));
        assert!(!is_rig(&dir));
        // Pure rig (home workspace has valid RigSelf, no joined)
        write(&format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{hex}"}}}}"#));
        assert!(is_rig(&dir));
        // Rig with all joined workspaces also valid rig
        write(&format!(
            r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{hex}"}},"joined":[{{"workspace":"ws-2","rig":{{"owner":"u2","person":"{hex}"}}}}]}}"#
        ));
        assert!(is_rig(&dir));
        // Rig with malformed joined entry `{}` (filtered out by joinedOf) is still rig
        write(&format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{hex}"}},"joined":[{{}}]}}"#));
        assert!(is_rig(&dir));
        // Mixed: home is rig, joined workspace is full (no rig)
        write(&format!(
            r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{hex}"}},"joined":[{{"workspace":"ws-2"}}]}}"#
        ));
        assert!(!is_rig(&dir));
        // Removed rig (numeric or null) is not active rig
        write(&format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{hex}"}},"removed_at":123}}"#));
        assert!(!is_rig(&dir));
        write(&format!(r#"{{"workspace":"ws-1","rig":{{"owner":"u1","person":"{hex}"}},"removed_at":null}}"#));
        assert!(!is_rig(&dir));
        // Empty workspace is not enrolled
        write(&format!(r#"{{"workspace":"","rig":{{"owner":"u1","person":"{hex}"}}}}"#));
        assert!(!is_rig(&dir));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn station_json_is_one_line_in_the_rust_stations_order() {
        let renew = if cfg!(unix) { ",\"renew\":1" } else { "" };
        assert_eq!(station_json(7, 12, "0.1.\"x", None), format!("{{\"pid\":7,\"startedAt\":12,\"version\":\"0.1.\\\"x\",\"handoff\":1,\"drain\":1,\"channel\":1{renew}}}\n"));
    }
}
