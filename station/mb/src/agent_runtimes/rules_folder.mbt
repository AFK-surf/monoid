// rules-folder.ts: a folder of a session's own that a runtime reading its rules from a project (Cursor's `.cursor`,
// Devin's `.devin`) is started in: the station's instructions as its always-on rule, the session's workspace's skills
// linked in.

///|
/// Where the folder of session `key` is under `runtime_home`.
pub fn rules_folder_dir(runtime_home : String, key : String) -> String {
  join([runtime_home, "station", sub(sha256_hex(key), 0, to=16)])
}

///|
/// `rulesFolder`: the folder made, its rule written as `rule_file` in `<dot>/rules`, an AGENTS.md of before taken away,
/// the skills at `skills` (where they are) linked as `<dot>/skills`. A link not made is let be (the log's).
pub async fn rules_folder(
  host : @host.Host,
  runtime_home : String,
  key : String,
  dot : String,
  rule_file : String,
  rule_text : String,
  skills? : String,
) -> String raise {
  let dir = rules_folder_dir(runtime_home, key)
  make_dir(host, join([dir, dot, "rules"]))
  write_file(host, join([dir, dot, "rules", rule_file]), rule_text)
  remove(host, join([dir, "AGENTS.md"]))
  if skills is Some(target) && exists(host, target) {
    let path = join([dir, dot, "skills"])
    remove(host, path, recursive=true)
    try symlink(host, target, path) catch {
      _ => ()
    }
  }
  dir
}

///|
/// cursor.ts `rulesFolder`'s rule: the station's instructions as a rule that always applies.
pub fn cursor_rule(instructions : String) -> String {
  "---\ndescription: still.fail station\nalwaysApply: true\n---\n\{instructions}\n"
}

///|
/// devin.ts `devinRules`: the station's instructions with how its tools are reached there.
pub fn devin_rules(instructions : String) -> String {
  "\{instructions}\{if instructions == "" { "" } else { "\n\n" }}The station's tools (chat_post, chat_state and the others named in these instructions) are the stillfail MCP server's: call one by its name (mcp__stillfail__chat_post and so on) without listing the server's tools first."
}

///|
/// devin.ts `rulesFolder`'s rule.
pub fn devin_rule(instructions : String) -> String {
  "---\ndescription: still.fail station\ntrigger: always_on\n---\n\{devin_rules(instructions)}\n"
}
