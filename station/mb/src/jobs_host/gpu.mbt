// The machine's GPUs, for other stations choosing where work goes (station/src/jobs/gpu.ts, linux-gpu.ts,
// amd-integrated.ts): on Apple Silicon the chip, GPU cores and utilization (ioreg), NVIDIA's through nvidia-smi when it
// is there (how busy they are and their memory, read again at most every ten seconds), Linux DRM cards, AMD models from
// Windows' video controllers, and an Intel Mac's discrete cards from system_profiler. Never more than a moment's wait:
// a command that does not answer within GPU_WAIT_MS counts as none.

///|
/// A GPU as the station says it (gpu.ts `Gpu`).
pub(all) struct Gpu {
  name : String
  cores : Double?
  memory_total : Double?
  memory_used : Double?
  busy : Double?
} derive(Eq, Show)

///|
pub fn Gpu::to_json(self : Gpu) -> Json {
  let m : Map[String, Json] = { "name": jstr(self.name) }
  match self.cores {
    Some(c) => m["cores"] = jnum(c)
    None => ()
  }
  match self.memory_total {
    Some(c) => m["memoryTotalBytes"] = jnum(c)
    None => ()
  }
  match self.memory_used {
    Some(c) => m["memoryUsedBytes"] = jnum(c)
    None => ()
  }
  match self.busy {
    Some(c) => m["busy"] = jnum(c)
    None => ()
  }
  Json::object(m)
}

///|
fn gpu_named(name : String) -> Gpu {
  { name, cores: None, memory_total: None, memory_used: None, busy: None }
}

///|
/// What a command printed: `Out`, `Failed` when it failed or took too long, `Absent` when there is no such command
/// (gpu.ts `Run`'s string, null and undefined).
pub(all) enum Ran {
  Out(String)
  Failed
  Absent
} derive(Eq, Show)

///|
pub let gpu_wait_ms : Int = 1500

///|
pub let nvidia_keep_ms : Double = 10_000.0

///|
pub let mac_displays_keep_ms : Double = 60_000.0

///|
let windows_amd : String = "(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\\VEN_1002*' } | Select-Object Name,PNPDeviceID) | ConvertTo-Json -Compress"

// ── AMD's integrated graphics ──

///|
let amd_integrated_ids : Array[String] = [
  "9870", "9874", "9875", "9876", "9877", "98e4", "15d8", "15dd", "15e7", "1636",
  "1638", "164c", "164d", "1681", "1435", "163f", "164e", "13c0", "1506", "15bf",
  "15c8", "1900", "1901", "150e", "1586", "1114", "1902",
]

///|
/// Whether an AMD PCI device id is one of a CPU's integrated graphics (amd-integrated.ts).
pub fn amd_integrated(device_id : String?) -> Bool {
  match device_id {
    None => false
    Some(id) => {
      let l = @jscase.lower(id)
      let bare = if starts(l, "0x") { from(l, 2) } else { l }
      amd_integrated_ids.contains(bare)
    }
  }
}

// ── what the commands print ──

///|
/// The first run of digits right after `prefix` (and, with `spaced_eq`, `\s*=\s*` between): `prefix(\d+)`.
fn digits_after(text : String, prefix : String, spaced_eq? : Bool = false) -> String? {
  let mut at = 0
  while true {
    let i = index_of(text, prefix, at~)
    if i < 0 {
      return None
    }
    let mut j = i + prefix.length()
    let mut ok = true
    if spaced_eq {
      while j < text.length() && @jscase.is_space(text.unsafe_charcode_at(j)) {
        j += 1
      }
      if j < text.length() && text.unsafe_charcode_at(j) == '=' {
        j += 1
        while j < text.length() && @jscase.is_space(text.unsafe_charcode_at(j)) {
          j += 1
        }
      } else {
        ok = false
      }
    }
    let start = j
    while j < text.length() && is_digit(text.unsafe_charcode_at(j)) {
      j += 1
    }
    if ok && j > start {
      return Some(slice(text, start, j))
    }
    at = i + 1
  }
  None
}

///|
/// Apple Silicon's GPU from `ioreg -rc AGXAccelerator -d1`, including its device utilization where reported.
pub fn apple_gpu(ioreg : String) -> Gpu? {
  // /"model" = "([^"]+)"/
  let mut name : String? = None
  let mut at = 0
  while name is None {
    let i = index_of(ioreg, "\"model\" = \"", at~)
    if i < 0 {
      break
    }
    let s = i + 11
    let e = index_of(ioreg, "\"", at=s)
    if e > s {
      name = Some(slice(ioreg, s, e))
    }
    at = i + 1
  }
  let cores = digits_after(ioreg, "\"gpu-core-count\" = ")
  let busy = digits_after(ioreg, "\"Device Utilization %\"", spaced_eq=true)
  if name is None && cores is None && busy is None {
    return None
  }
  let percent = busy.map(digits_number)
  Some({
    name: name.unwrap_or("Apple GPU"),
    cores: cores.map(digits_number),
    memory_total: None,
    memory_used: None,
    busy: match percent {
      Some(p) if p <= 100.0 => Some(p / 100.0)
      _ => None
    },
  })
}

///|
/// NVIDIA's GPUs from `nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu
/// --format=csv,noheader,nounits`: a line each, memory in MiB, how busy in percent ("[N/A]" where it cannot say).
pub fn nvidia_gpus(csv : String) -> Array[Gpu] {
  let out = []
  for line in split(csv, "\n") {
    let parts = split(line, ",").map(trim)
    let name = parts[0]
    if name == "" {
      continue
    }
    let value = (i : Int) => if i < parts.length() && decimal(parts[i]) {
      Some(digits_number(parts[i]))
    } else {
      None
    }
    out.push({
      name,
      cores: None,
      memory_total: value(1).map(v => v * 1024.0 * 1024.0),
      memory_used: value(2).map(v => v * 1024.0 * 1024.0),
      busy: value(3).map(v => js_round(v) / 100.0),
    })
  }
  out
}

///|
/// `(?:^|&)DEV_([0-9a-f]{4})(?:&|$)`, case aside.
fn amd_device_of(pnp : String) -> String? {
  for part in split(pnp, "&") {
    if part.length() == 8 && lower_ascii(slice(part, 0, 4)) == "dev_" {
      let id = from(part, 4)
      let mut hex = true
      for i in 0..<4 {
        let c = id.unsafe_charcode_at(i)
        if !(is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
          hex = false
        }
      }
      if hex {
        return Some(id)
      }
    }
  }
  None
}

///|
/// Windows PowerShell 5.1 returns one controller as an object and several as an array. Empty or unreadable is none.
pub fn windows_amd_gpus(text : String) -> Array[Gpu] {
  let v = @json.parse(text) catch {
    _ => return []
  }
  let controllers = match v {
    Array(a) => a
    other => [other]
  }
  let out = []
  for c in controllers {
    guard c is Object(_) else { continue }
    guard field(c, "Name") is Some(String(name)) && trim(name) != "" else { continue }
    let id = match field(c, "PNPDeviceID") {
      Some(String(p)) => amd_device_of(p)
      _ => None
    }
    if !amd_integrated(id) {
      out.push(gpu_named(trim(name)))
    }
  }
  out
}

///|
/// `(?:^|[_\W])word(?:$|[_\W])`, case aside: `word` one of the text's runs of letters and digits.
fn has_token(s : String, words : Array[String]) -> Bool {
  let alnum = (c : Int) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c)
  let mut i = 0
  while i < s.length() {
    if alnum(s.unsafe_charcode_at(i)) {
      let start = i
      while i < s.length() && alnum(s.unsafe_charcode_at(i)) {
        i += 1
      }
      if words.contains(lower_ascii(slice(s, start, i))) {
        return true
      }
    } else {
      i += 1
    }
  }
  false
}

///|
/// An Intel Mac's discrete GPU: its vendor ("amd" or "nvidia") and what is known of it.
pub(all) struct VendorGpu {
  vendor : String
  gpu : Gpu
} derive(Eq, Show)

///|
/// `^\s*(\d+(?:\.\d+)?)\s*(GB|MB)\s*$`, case aside: the bytes it says.
fn vram_bytes(s : String) -> Double? {
  let t = trim(s)
  let mut i = 0
  while i < t.length() && (is_digit(t.unsafe_charcode_at(i)) || t.unsafe_charcode_at(i) == '.') {
    i += 1
  }
  let n = slice(t, 0, i)
  if !decimal(n) {
    return None
  }
  let mut j = i
  while j < t.length() && @jscase.is_space(t.unsafe_charcode_at(j)) {
    j += 1
  }
  match lower_ascii(from(t, j)) {
    "gb" => Some(digits_number(n) * 1073741824.0)
    "mb" => Some(digits_number(n) * 1048576.0)
    _ => None
  }
}

///|
/// Intel Macs can have an AMD or NVIDIA PCIe GPU alongside Intel's integrated graphics. `system_profiler` says the
/// discrete cards' models and total VRAM, but not their current use.
pub fn mac_discrete_gpus(text : String) -> Array[VendorGpu] {
  let v = @json.parse(text) catch {
    _ => return []
  }
  guard field(v, "SPDisplaysDataType") is Some(Array(entries)) else { return [] }
  let out = []
  for e in entries {
    guard e is Object(_) else { continue }
    guard field(e, "sppci_bus") is Some(String("spdisplays_pcie_device")) else { continue }
    guard field(e, "spdisplays_vendor") is Some(String(vendor_text)) else { continue }
    let vendor = if has_token(vendor_text, ["amd", "ati"]) {
      "amd"
    } else if has_token(vendor_text, ["nvidia"]) {
      "nvidia"
    } else {
      continue
    }
    let name = match field(e, "sppci_model") {
      Some(String(m)) if trim(m) != "" => trim(m)
      _ => if vendor == "amd" { "AMD GPU" } else { "NVIDIA GPU" }
    }
    let vram = match field(e, "spdisplays_vram") {
      Some(Null) | None => field_or_null(e, "_spdisplays_vram")
      Some(x) => x
    }
    let memory = match vram {
      String(s) => vram_bytes(s)
      _ => None
    }
    out.push(VendorGpu::{ vendor, gpu: { ..gpu_named(name), memory_total: memory } })
  }
  out
}

// ── Linux's DRM cards ──

///|
/// A Linux card: its PCI vendor ("0x1002", "0x10de") and what is known of it.
pub(all) struct LinuxGpu {
  vendor : String
  gpu : Gpu
} derive(Eq, Show)

///|
/// Whether a line is only white space (`\s*`).
fn blank(line : String) -> Bool {
  for i in 0..<line.length() {
    if !@jscase.is_space(line.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// PCI slots and their device names from `lspci -D -vmm` (linux-gpu.ts `pciNames`): its blocks split at /\n\s*\n/.
pub fn pci_names(text : String) -> Map[String, String] {
  let names : Map[String, String] = Map([])
  let lines = split(text, "\n")
  let blocks : Array[Array[String]] = [[]]
  for i, line in lines {
    // (a line between two "\n" of only white space ends a block)
    if i > 0 && i < lines.length() - 1 && blank(line) {
      if blocks[blocks.length() - 1].length() > 0 {
        blocks.push([])
      }
      continue
    }
    blocks[blocks.length() - 1].push(line)
  }
  for block in blocks {
    let fields : Map[String, String] = Map([])
    for line in block {
      let i = index_of(line, ":\t")
      if i >= 0 {
        fields[slice(line, 0, i)] = trim(from(line, i + 2))
      }
    }
    match (fields.get("Slot"), fields.get("Device")) {
      (Some(slot), Some(device)) if slot != "" && device != "" =>
        names[@jscase.lower(slot)] = device
      _ => ()
    }
  }
  names
}

///|
/// What linux_gpus reads of the disk and runs: a file's text trimmed, a path's realpath, a directory's names, lspci.
pub(all) struct LinuxIo {
  read : async (String) -> String?
  realpath : async (String) -> String?
  readdir : async (String) -> Array[String]
  run : async (String, Array[String], Int) -> Ran
}

///|
/// The machine's own.
pub fn LinuxIo::shell(host : @host.Host, run : async (String, Array[String], Int) -> Ran) -> LinuxIo {
  {
    read: async fn(p) { read_text(host, p).map(trim) },
    realpath: async fn(p) {
      match try_ask(host, "fs.realpath", { "path": jstr(p) }) {
        Some(String(s)) => Some(s)
        _ => None
      }
    },
    readdir: async fn(p) { readdir(host, p).unwrap_or([]) },
    run,
  }
}

///|
fn number_text(s : String?) -> Double? {
  match s {
    Some(t) if all_digits(t) => {
      let d = digits_number(t)
      if safe_integer(d) {
        Some(d)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Linux DRM cards: AMD and NVIDIA when nvidia-smi cannot see it (linux-gpu.ts `linuxGpus`).
pub async fn linux_gpus(io : LinuxIo, root? : String = "/sys/class/drm") -> Array[LinuxGpu] {
  let names = (io.readdir)(root).filter(n => starts(n, "card") && all_digits(from(n, 4)))
  names.sort_by((a, b) => digits_number(from(a, 4)).compare(digits_number(from(b, 4))))
  let cards = []
  for entry in names {
    let path = pjoin([root, entry, "device"])
    let vendor = (io.read)(pjoin([path, "vendor"]))
    let device = (io.realpath)(path)
    let pci_id = (io.read)(pjoin([path, "device"]))
    let busy = (io.read)(pjoin([path, "gpu_busy_percent"]))
    let total = (io.read)(pjoin([path, "mem_info_vram_total"]))
    let used = (io.read)(pjoin([path, "mem_info_vram_used"]))
    let id = vendor.map(@jscase.lower)
    guard id is Some(id) && (id == "0x1002" || id == "0x10de") else { continue }
    if id == "0x1002" && amd_integrated(pci_id) {
      continue
    }
    guard device is Some(device) else { continue }
    cards.push((id, @jscase.lower(@nodepath.basename("/", device)), busy, total, used))
  }
  if cards.is_empty() {
    return []
  }
  let out = (io.run)("lspci", ["-D", "-vmm"], 1500)
  let names = pci_names(
    match out {
      Out(s) => s
      _ => ""
    },
  )
  let seen : Map[String, Bool] = Map([])
  let found = []
  for card in cards {
    let (vendor_id, slot, busy, total, used) = card
    if seen.contains(slot) {
      continue
    }
    seen[slot] = true
    let vendor = if vendor_id == "0x1002" { "AMD" } else { "NVIDIA" }
    let name = match names.get(slot) {
      Some(model) => "\{vendor} \{model}"
      None => "\{vendor} GPU"
    }
    let b = number_text(busy)
    let t = number_text(total)
    found.push(LinuxGpu::{
      vendor: vendor_id,
      gpu: {
        name,
        cores: None,
        busy: match b {
          Some(b) if b <= 100.0 => Some(b / 100.0)
          _ => None
        },
        memory_total: match t {
          Some(t) if t > 0.0 => Some(t)
          _ => None
        },
        memory_used: number_text(used),
      },
    })
  }
  found
}

// ── the machine's GPUs, kept a while ──

///|
/// The GPUs as gpu.ts `Gpus` reads them: each command asked again once its answer is old, the last given meanwhile.
pub struct Gpus {
  priv run : async (String, Array[String], Int) -> Ran
  priv os : String
  priv arch : String
  priv now : () -> Double
  priv linux_read : async () -> Array[LinuxGpu]
  priv mut apple : (Double, Gpu?)?
  priv mut nvidia : (Double, Array[Gpu])?
  priv mut absent : Bool
  priv mut linux : (Double, Array[LinuxGpu])?
  priv mut windows : (Double, Array[Gpu])?
  priv mut mac_displays : (Double, Array[VendorGpu])?
}

///|
pub fn Gpus::new(
  run : async (String, Array[String], Int) -> Ran,
  os : String,
  arch : String,
  now : () -> Double,
  linux : async () -> Array[LinuxGpu],
) -> Gpus {
  {
    run,
    os,
    arch,
    now,
    linux_read: linux,
    apple: None,
    nvidia: None,
    absent: false,
    linux: None,
    windows: None,
    mac_displays: None,
  }
}

///|
/// A command run on the shell (gpu.ts's `run`): what it printed, Failed where it failed or took longer than `ms`,
/// Absent where there is no such command.
pub async fn run_on(host : @host.Host, file : String, args : Array[String], ms : Int) -> Ran {
  match run_program(host, file, args, timeout_ms=ms) {
    Some(out) => Out(out)
    None =>
      // (not started, or ended otherwise: whether it is there at all)
      match run_code(host, "/bin/sh", ["-c", "command -v \"$0\" >/dev/null 2>&1", file]) {
        Some((0, _)) => Failed
        Some(_) => Absent
        None => Failed
      }
  }
}

///|
fn Gpus::merged(self : Gpus) -> Array[Gpu] {
  let gpus = []
  if self.os == "macos" && self.arch == "arm64" {
    match self.apple {
      Some((_, Some(g))) => gpus.push(g)
      _ => ()
    }
  }
  if !self.absent {
    match self.nvidia {
      Some((_, g)) => gpus.push_iter(g.iter())
      None => ()
    }
  }
  if self.os == "linux" {
    let has_nvidia = gpus.length() > 0
    match self.linux {
      Some((_, cards)) =>
        for c in cards {
          if c.vendor != "0x10de" || !has_nvidia {
            gpus.push(c.gpu)
          }
        }
      None => ()
    }
  }
  if self.os == "macos" && self.arch == "x64" {
    let has_nvidia = gpus.length() > 0
    match self.mac_displays {
      Some((_, cards)) =>
        for c in cards {
          if c.vendor != "nvidia" || !has_nvidia {
            gpus.push(c.gpu)
          }
        }
      None => ()
    }
  }
  if self.os == "windows" {
    match self.windows {
      Some((_, g)) => gpus.push_iter(g.iter())
      None => ()
    }
  }
  gpus
}

///|
/// The GPUs as last read, none asked or waited for; None where none is known yet.
pub fn Gpus::cached(self : Gpus) -> Array[Gpu]? {
  let gpus = self.merged()
  if gpus.is_empty() {
    None
  } else {
    Some(gpus)
  }
}

///|
fn[X] old(at : (Double, X)?, now : Double, keep : Double) -> Bool {
  match at {
    None => true
    Some((t, _)) => now - t >= keep
  }
}

///|
/// The GPUs, or None when none is known: each source asked again once its answer is NVIDIA_KEEP_MS old
/// (system_profiler's MAC_DISPLAYS_KEEP_MS).
pub async fn Gpus::read(self : Gpus) -> Array[Gpu]? {
  let ran = (out : Ran) => match out {
    Out(s) => Some(s)
    _ => None
  }
  if self.os == "macos" &&
    self.arch == "x64" &&
    old(self.mac_displays, (self.now)(), mac_displays_keep_ms) {
    let at = (self.now)()
    let out = (self.run)("system_profiler", ["SPDisplaysDataType", "-json"], gpu_wait_ms)
    self.mac_displays = Some((at, ran(out).map(mac_discrete_gpus).unwrap_or([])))
  }
  if self.os == "linux" && old(self.linux, (self.now)(), nvidia_keep_ms) {
    let at = (self.now)()
    let cards = (self.linux_read)() catch { _ => [] }
    self.linux = Some((at, cards))
  }
  if self.os == "windows" && old(self.windows, (self.now)(), nvidia_keep_ms) {
    let at = (self.now)()
    let out = (self.run)(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", windows_amd],
      gpu_wait_ms,
    )
    self.windows = Some((at, ran(out).map(windows_amd_gpus).unwrap_or([])))
  }
  if self.os == "macos" &&
    self.arch == "arm64" &&
    old(self.apple, (self.now)(), nvidia_keep_ms) {
    let at = (self.now)()
    let out = (self.run)("ioreg", ["-rc", "AGXAccelerator", "-d1"], gpu_wait_ms)
    self.apple = Some((at, ran(out).bind(apple_gpu)))
  }
  if !self.absent && old(self.nvidia, (self.now)(), nvidia_keep_ms) {
    let at = (self.now)()
    let out = (self.run)(
      "nvidia-smi",
      [
        "--query-gpu=name,memory.total,memory.used,utilization.gpu", "--format=csv,noheader,nounits",
      ],
      gpu_wait_ms,
    )
    if out is Absent {
      self.absent = true
    }
    self.nvidia = Some((at, ran(out).map(nvidia_gpus).unwrap_or([])))
  }
  self.cached()
}
