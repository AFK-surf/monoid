//! What the launcher tells the Node it starts of itself (`--launcher-…`, read by station/src/ops/launcher.ts) is the
//! same on Unix (src/run.rs) and Windows (src/run_windows.rs): Windows' launcher once left out `--launcher-carries`,
//! so Node there carried nothing at a handover (the vault's grants lost with every update). Read from the sources, so
//! it holds on every system, Windows' launcher built or not.

const UNIX: &str = include_str!("../src/run.rs");
const WINDOWS: &str = include_str!("../src/run_windows.rs");
const NODE: &str = include_str!("../../../src/ops/launcher.ts");

/// The flags Node goes by that are only said (no value after them): `args.includes("--launcher-…")`.
fn said_flags() -> Vec<String> {
    NODE.split("args.includes(\"").skip(1).filter_map(|rest| rest.split('"').next()).filter(|f| f.starts_with("--launcher-")).map(str::to_string).collect()
}

#[test]
fn every_flag_node_goes_by_is_given_by_both_launchers() {
    let flags = said_flags();
    assert!(flags.contains(&"--launcher-carries".to_string()) && flags.contains(&"--launcher-heartbeat".to_string()), "{flags:?}");
    for flag in &flags {
        let quoted = format!("\"{flag}\"");
        assert!(UNIX.contains(&quoted), "run.rs does not give Node {flag}");
        // (Windows' installer runs as a scheduled task the station registers, which the launcher does not start: it says
        // it starts none, and Node asks it for none there)
        if flag == "--launcher-installer" {
            assert!(!WINDOWS.contains(&quoted), "run_windows.rs gives Node {flag} with no installer of its own to start");
            continue;
        }
        assert!(WINDOWS.contains(&quoted), "run_windows.rs does not give Node {flag}");
    }
}
