// repo-rules.ts: the hooks a session's runtime runs as a command (the repository's rules told as its tools first touch
// a repository, ./repo-rules-hook.mjs), each run by the release's own Node beside the hook's file.

///|
/// `hookNode`: the Node a hook's command names, the release's own beside its file (<app>/node: bin/node, or node.exe on
/// Windows), whichever `has`; else `exec_path` (process.execPath).
pub fn hook_node(file : String, has : (String) -> Bool, exec_path : String) -> String {
  let node = join([dirname(dirname(file)), "node"])
  for own in [join([node, "bin", "node"]), join([node, "node.exe"])] {
    if has(own) {
      return own
    }
  }
  exec_path
}

///|
/// `hookCommand`: a hook's file as a command, each word in single quotes, failing quietly.
pub fn hook_command(node : String, file : String, args : Array[String]) -> String {
  let words = [node, file]
  words.push_iter(args.iter())
  "\{words.map(sh_quoted).join(" ")} 2>/dev/null || true"
}

///|
fn cmd_quoted(s : String) -> String {
  "\"\{replace_all(s, "\"", "")}\""
}

///|
/// `agyHookCommand`: a hook's file as Antigravity CLI runs it (`sh -c` on Unix, `cmd /c` on Windows), `{}` on stdout
/// when the station's files are missing.
pub fn agy_hook_command(node : String, file : String, os : String) -> String {
  if os == "windows" {
    "call \{[node, file].map(cmd_quoted).join(" ")} 2>nul || echo {}"
  } else {
    "\{[node, file].map(sh_quoted).join(" ")} 2>/dev/null || printf '{}'"
  }
}
