///|
/// The packer the shell gives (`zstd.compress`, `zstd.stream`).
pub fn shell_packer(host : @host.Host) -> @door.Packer {
  let num = (n : Int) => Json::number(n.to_double())
  {
    whole: async fn(bytes : Bytes, level : Int) -> Bytes {
      let (_, out) = host.shell("zstd.compress", { "level": num(level), "window": num(@door.window_log) }, bytes~)
      out.unwrap_or(b"")
    },
    stream: async fn() -> @door.Packing {
      let (made, _) = host.shell("zstd.stream", { "level": num(@door.level), "window": num(@door.window_log) })
      let id = match made { { "id": id, .. } => id; _ => Json::null() }
      {
        push: async fn(piece : Bytes) -> Bytes { host.shell("zstd.push", { "id": id }, bytes=piece).1.unwrap_or(b"") },
        finish: async fn() -> Bytes { host.shell("zstd.push", { "id": id, "finish": Json::boolean(true) }, bytes=b"").1.unwrap_or(b"") },
        close: () => ignore(host.rt.fork_quiet(() => ignore(host.shell("zstd.close", { "id": id })) catch { _ => () })),
      }
    },
  }
}
