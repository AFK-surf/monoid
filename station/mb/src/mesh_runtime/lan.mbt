// Where a device on the station's LAN can dial it straight (station/src/mesh/lan.ts): the station's private IPv4
// addresses, each at its mesh port, told a member as its credential checks out (serve.ts); its Tailscale addresses
// likewise; an address on each LAN it is on that is not its own (the subnet's first, its router as a rule), and
// whether this process may reach that LAN at all (macOS refuses a process its app was not let reach the local network
// with EHOSTUNREACH). The machine's interfaces are given, as `os.networkInterfaces()` lists them, and the one byte sent
// to a neighbour's discard port by what the caller gives.

///|
/// One address of an interface (`NetworkInterfaceInfo`).
pub(all) struct Iface {
  address : String
  netmask : String
  family : String
  internal : Bool
}

///|
/// An interface's addresses as JSON says them (`{address, netmask, family, internal}`).
pub fn Iface::of_json(v : Json) -> Iface {
  {
    address: str_of(field(v, "address")).unwrap_or(""),
    netmask: str_of(field(v, "netmask")).unwrap_or(""),
    family: str_of(field(v, "family")).unwrap_or(""),
    internal: field(v, "internal") is Some(True),
  }
}

///|
/// The machine's interfaces in their order (`Object.entries(networkInterfaces())`).
pub fn interfaces_of_json(v : Json) -> Array[(String, Array[Iface])] {
  let out = []
  if v is Object(m) {
    for name, addrs in m {
      out.push((name, if addrs is Array(xs) { xs.map(Iface::of_json) } else { [] }))
    }
  }
  out
}

///|
/// Interfaces no device on the LAN reaches the station through: VM and container bridges, tunnels, Apple's peer-to-peer
/// links (`NOT_LAN`).
pub fn not_lan(name : String) -> Bool {
  for p in ["bridge", "utun", "vmnet", "vboxnet", "docker", "veth", "br-", "llw", "awdl", "anpi", "gif", "stf", "lo"] {
    if name.has_prefix(p) {
      return true
    }
  }
  // `ap\d`
  name.length() >= 3 && name.has_prefix("ap") && is_digit(name.code_unit_at(2).to_int())
}

///|
/// The four parts of a dotted address as `ip.split(".").map(Number)` has them.
fn octets(ip : String) -> Array[Double] {
  ip.split(".").map(p => js_number(p.to_owned())).to_array()
}

///|
fn byte_octets(o : Array[Double]) -> Bool {
  o.length() == 4 && o.iter().all(n => js_is_integer(n) && n >= 0.0 && n <= 255.0)
}

///|
/// Whether `ip` is a private IPv4 address (RFC 1918).
pub fn private_v4(ip : String) -> Bool {
  let o = octets(ip)
  if !byte_octets(o) {
    return false
  }
  o[0] == 10.0 || (o[0] == 172.0 && o[1] >= 16.0 && o[1] <= 31.0) || (o[0] == 192.0 && o[1] == 168.0)
}

///|
/// Whether `ip` is in Tailscale's IPv4 range (100.64.0.0/10).
pub fn tailnet_v4(ip : String) -> Bool {
  let o = octets(ip)
  if !byte_octets(o) {
    return false
  }
  o[0] == 100.0 && o[1] >= 64.0 && o[1] <= 127.0
}

///|
/// `/^(\d+\.\d+\.\d+\.\d+):(\d+)$/` of `s`: the address and the port.
fn v4_socket(s : String) -> (String, String)? {
  let n = s.length()
  let at = (i : Int) => s.code_unit_at(i).to_int()
  let mut i = 0
  for part in 0..<4 {
    let from = i
    while i < n && is_digit(at(i)) {
      i += 1
    }
    if i == from {
      return None
    }
    if part < 3 {
      if i >= n || at(i) != 0x2e {
        return None
      }
      i += 1
    }
  }
  let ip_end = i
  if i >= n || at(i) != 0x3a {
    return None
  }
  i += 1
  let port_from = i
  while i < n && is_digit(at(i)) {
    i += 1
  }
  if i == port_from || i != n {
    return None
  }
  Some((s.clamped_view(end=ip_end).to_owned(), s.clamped_view(start=port_from).to_owned()))
}

///|
fn unique(xs : Array[String]) -> Array[String] {
  let seen : Map[String, Unit] = Map([])
  let out = []
  for x in xs {
    if !seen.contains(x) {
      seen[x] = ()
      out.push(x)
    }
  }
  out
}

///|
fn addrs_where(
  sockets : Array[String],
  interfaces : Array[(String, Array[Iface])],
  lan : Bool,
) -> Array[String] {
  let mut v4 = None
  for s in sockets {
    if v4_socket(s) is Some(m) {
      v4 = Some(m)
      break
    }
  }
  guard v4 is Some((bound, port)) else { return [] }
  let out = []
  for named in interfaces {
    let (name, addrs) = named
    if lan && not_lan(name) {
      continue
    }
    for a in addrs {
      let kind = if lan { private_v4(a.address) } else { tailnet_v4(a.address) }
      if a.family != "IPv4" || a.internal || !kind {
        continue
      }
      if bound != "0.0.0.0" && bound != a.address {
        continue
      }
      out.push("\{a.address}:\{port}")
    }
  }
  unique(out)
}

///|
/// `ip:port` of each private IPv4 address the station has on a LAN interface, at the port of its IPv4 socket
/// (`sockets`, as the endpoint gives them); none when that socket is not at `0.0.0.0` or that address.
pub fn lan_addrs(sockets : Array[String], interfaces : Array[(String, Array[Iface])]) -> Array[String] {
  addrs_where(sockets, interfaces, true)
}

///|
/// `ip:port` of each Tailscale address the station has, at the port of its IPv4 socket (as `lan_addrs`), known by the
/// address, not the interface.
pub fn tailnet_addrs(sockets : Array[String], interfaces : Array[(String, Array[Iface])]) -> Array[String] {
  addrs_where(sockets, interfaces, false)
}

///|
/// `ip.split(".").reduce((n, o) => (n * 256 + Number(o)) >>> 0, 0)`.
fn v4_of(ip : String) -> Double {
  let mut n = 0.0
  for o in octets(ip) {
    n = to_uint32(n * 256.0 + o)
  }
  n
}

///|
/// ToInt32, as a Double.
fn to_int32(n : Double) -> Double {
  let u = to_uint32(n)
  if u >= 2147483648.0 {
    u - 4294967296.0
  } else {
    u
  }
}

///|
/// `a & b` of two numbers as JavaScript takes them (ToInt32 each).
fn js_and(a : Double, b : Double) -> Double {
  let x = to_int32(a).to_int()
  let y = to_int32(b).to_int()
  (x & y).to_double()
}

///|
/// `[24, 16, 8, 0].map((s) => (n >>> s) & 255).join(".")`.
fn dotted(n : Double) -> String {
  let u = to_uint32(n)
  let parts = [24, 16, 8, 0].map(s => ((u / (1 << s).to_double()).floor().to_int64() & 255L).to_string())
  parts.join(".")
}

///|
/// An address on each LAN the station is on, not its own: the subnet's first (its router, as a rule).
pub fn lan_neighbours(interfaces : Array[(String, Array[Iface])]) -> Array[String] {
  let out = []
  for named in interfaces {
    let (name, addrs) = named
    if not_lan(name) {
      continue
    }
    for a in addrs {
      if a.family != "IPv4" || a.internal || !private_v4(a.address) || a.netmask == "" {
        continue
      }
      let first = to_uint32(js_and(v4_of(a.address), v4_of(a.netmask))) + 1.0
      out.push(dotted(if dotted(first) == a.address { first + 1.0 } else { first }))
    }
  }
  unique(out)
}

///|
/// Whether this process may reach the LAN it is on: "granted" once one of its LANs takes a byte (`send` gives None),
/// "denied" when each refused it with EHOSTUNREACH, None with no LAN (or none of either). Each neighbour is sent its
/// byte at once.
pub async fn lan_reach(neighbours : Array[String], send : async (String) -> String?) -> String? {
  let said = @effect.all(neighbours.map(ip => async fn() -> String? { send(ip) }))
  if said.iter().any(e => e is None) {
    return Some("granted")
  }
  if said.length() > 0 && said.iter().all(e => e is Some("EHOSTUNREACH")) {
    Some("denied")
  } else {
    None
  }
}

///|
/// System Settings' Local Network list, where an app is let reach the LAN.
pub let local_network_settings : String = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
