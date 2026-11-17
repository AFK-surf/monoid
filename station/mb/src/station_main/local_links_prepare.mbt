// local.rs `prepare_local_links` (media/local_links.mbt) on this machine's files: what a post names of them made into
// its attachments before it is posted (sessions/local-links.ts `prepare`, which asked the mesh addon).

///|
/// This machine as the links are read against it.
pub fn machine_link_world() -> @media.LinkWorld {
  {
    sep: if is_windows() { "\\" } else { "/" },
    is_file: p => match attempt(() => @drive.stat(p)) {
      Ok(s) => s.file
      Err(_) => false
    },
    realpath: p => attempt(() => @drive.realpath(p)).to_option(),
  }
}

///|
/// `text` with its local links made to name its attachments, and those (`paths` and the files the links name); the
/// refusal's words where it is refused.
pub fn prepare_local_links(text : String, paths : Array[String], workspace : String) -> Result[(String, Array[String]), String] {
  try Ok(@media.prepare_local_links(machine_link_world(), text, paths, workspace)) catch {
    @media.LinkRefused(why) => Err(why)
  }
}
