// The keeper's ssh-agent (station/src/vault/ssh-agent.ts, 三种用法): a socket for one command run with a granted SSH
// key, which lists that key and signs with it, so the key itself never leaves the keeper. The agent protocol's few
// messages it needs (draft-miller-ssh-agent): list identities, sign; anything else fails. Keys are OpenSSH's own format
// (`openssh-key-v1`, unencrypted) or PEM, Ed25519 or RSA. The key's signatures are the machine's (machine.mbt `sign`).

///|
let request_identities : Int = 11

///|
let identities_answer : Int = 12

///|
let sign_request : Int = 13

///|
let sign_response : Int = 14

///|
let agent_failure : Int = 5

///|
let rsa_sha2_256 : Int = 2

///|
let rsa_sha2_512 : Int = 4

///|
/// A key as the agent holds it: the private key, and its public blob as SSH writes it.
pub(all) struct SshKey {
  key : KeyRef
  blob : Bytes
  kind : String
  comment : String
}

///|
fn u32(n : Int) -> Bytes {
  Bytes::from_array([
    ((n >> 24) & 0xff).to_byte(),
    ((n >> 16) & 0xff).to_byte(),
    ((n >> 8) & 0xff).to_byte(),
    (n & 0xff).to_byte(),
  ])
}

///|
fn ssh_string(b : Bytes) -> Bytes {
  cat([u32(b.length()), b])
}

///|
/// An mpint from big-endian unsigned bytes.
fn mpint(b : Bytes) -> Bytes {
  let mut i = 0
  while i < b.length() && b[i] == b'\x00' {
    i += 1
  }
  let v = sub(b, i, b.length())
  if v.length() > 0 && (v[0].to_int() & 0x80) != 0 {
    ssh_string(cat([b"\x00", v]))
  } else {
    ssh_string(v)
  }
}

///|
/// SSH's wire types read off bytes, raising past their end.
priv struct WireReader {
  b : Bytes
  mut at : Int
}

///|
fn WireReader::u32(self : WireReader) -> Int raise {
  if self.at + 4 > self.b.length() {
    raise Failure("truncated")
  }
  let v = (self.b[self.at].to_int() << 24) |
    (self.b[self.at + 1].to_int() << 16) |
    (self.b[self.at + 2].to_int() << 8) |
    self.b[self.at + 3].to_int()
  self.at += 4
  v
}

///|
fn WireReader::bytes(self : WireReader) -> Bytes raise {
  let n = self.u32()
  // (an unsigned length past what a signed one holds is past the end too)
  if n < 0 || self.at + n > self.b.length() {
    raise Failure("truncated")
  }
  let v = sub(self.b, self.at, self.at + n)
  self.at += n
  v
}

///|
fn WireReader::text(self : WireReader) -> String raise {
  utf8_text(self.bytes())
}

///|
/// Base64url of big-endian bytes, leading zeros taken off (one kept).
fn b64u(b : Bytes) -> String {
  let mut i = 0
  while i < b.length() - 1 && b[i] == b'\x00' {
    i += 1
  }
  @vault_crypto.b64url(sub(b, i, b.length()))
}

///|
/// The agent's view of a key the machine holds.
fn from_key(k : KeyRef, comment : String) -> SshKey raise {
  if k.kind == "ed25519" {
    return {
      key: k,
      kind: "ssh-ed25519",
      comment,
      blob: cat([ssh_string(ascii("ssh-ed25519")), ssh_string(k.public[0])]),
    }
  }
  if k.kind == "rsa" {
    return {
      key: k,
      kind: "ssh-rsa",
      comment,
      blob: cat([ssh_string(ascii("ssh-rsa")), mpint(k.public[0]), mpint(k.public[1])]),
    }
  }
  raise Failure("only Ed25519 and RSA SSH keys are supported")
}

///|
/// The bytes between `-----BEGIN OPENSSH PRIVATE KEY-----` and its end, where there are both.
fn openssh_body(text : String) -> String? {
  let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
  let end = "-----END OPENSSH PRIVATE KEY-----"
  match text.find(begin) {
    Some(i) => {
      let rest = slice(text, i + begin.length())
      match rest.find(end) {
        Some(j) => Some(slice(rest, 0, b=j))
        None => None
      }
    }
    None => None
  }
}

///|
/// A private key from its text: OpenSSH's format (unencrypted) or PEM.
pub async fn parse_ssh_key(m : Machine, text : String) -> SshKey {
  let body = match openssh_body(text) {
    None =>
      match (m.key_of_pem)(text) {
        Some(k) => return from_key(k, "")
        None => raise Failure("not a private key")
      }
    Some(b) => b
  }
  let compact = StringBuilder()
  for i in 0..<body.length() {
    let c = body.code_unit_at(i).to_int()
    if !js_space(c) {
      compact.write_char(c.unsafe_to_char())
    }
  }
  let raw = @vault_crypto.unb64(compact.to_string())
  let magic = "openssh-key-v1\u{0}"
  if raw.length() < magic.length() || latin1(sub(raw, 0, magic.length())) != magic {
    raise Failure("not an OpenSSH private key")
  }
  let r : WireReader = { b: sub(raw, magic.length(), raw.length()), at: 0 }
  let cipher = r.text()
  ignore(r.text())
  ignore(r.bytes())
  if cipher != "none" {
    raise Failure("the SSH key has a passphrase: store it without one (the vault keeps it encrypted)")
  }
  if r.u32() != 1 {
    raise Failure("one key per SSH key file")
  }
  ignore(r.bytes())
  let p : WireReader = { b: r.bytes(), at: 0 }
  if p.u32() != p.u32() {
    raise Failure("the SSH key is damaged")
  }
  let kind = p.text()
  if kind == "ssh-ed25519" {
    ignore(p.bytes())
    let secret = p.bytes()
    if secret.length() < 32 {
      raise Failure("the SSH key is damaged")
    }
    let seed = sub(secret, 0, 32)
    return from_key((m.ed25519_of_seed)(seed), p.text())
  }
  if kind == "ssh-rsa" {
    let n = p.bytes()
    let e = p.bytes()
    let d = p.bytes()
    let iqmp = p.bytes()
    let pp = p.bytes()
    let q = p.bytes()
    let comment = p.text()
    let key = (m.rsa_of_jwk)(
      obj([
        ("kty", js("RSA")),
        ("n", js(b64u(n))),
        ("e", js(b64u(e))),
        ("d", js(b64u(d))),
        ("p", js(b64u(pp))),
        ("q", js(b64u(q))),
        ("qi", js(b64u(iqmp))),
      ]),
    )
    return from_key(key, comment)
  }
  raise Failure("only Ed25519 and RSA SSH keys are supported, not \{kind}")
}

///|
/// The signature blob for `data` with `k`, as `flags` ask (RSA: SHA-2 when asked, else SHA-1 as ssh-rsa).
pub async fn ssh_sign(m : Machine, k : SshKey, data : Bytes, flags : Int) -> Bytes {
  if k.kind == "ssh-ed25519" {
    return cat([ssh_string(ascii("ssh-ed25519")), ssh_string((m.sign)(k.key, "", data))])
  }
  let (name, hash) = if (flags & rsa_sha2_512) != 0 {
    ("rsa-sha2-512", "sha512")
  } else if (flags & rsa_sha2_256) != 0 {
    ("rsa-sha2-256", "sha256")
  } else {
    ("ssh-rsa", "sha1")
  }
  cat([ssh_string(ascii(name)), ssh_string((m.sign)(k.key, hash, data))])
}

///|
/// The answer to one agent message (its type byte and payload); `allowed` is asked before each signature.
pub async fn agent_answer(m : Machine, k : SshKey, message : Bytes, allowed : () -> Bool) -> Bytes noraise {
  let kind = if message.length() > 0 { message[0].to_int() } else { -1 }
  let answered = (async fn() -> Bytes? raise {
    if kind == request_identities {
      return Some(
        cat([
          Bytes::make(1, identities_answer.to_byte()),
          u32(1),
          ssh_string(k.blob),
          ssh_string(utf8_of(k.comment)),
        ]),
      )
    }
    if kind == sign_request {
      let r : WireReader = { b: sub(message, 1, message.length()), at: 0 }
      let blob = r.bytes()
      let data = r.bytes()
      let flags = r.u32()
      if blob == k.blob && allowed() {
        return Some(cat([Bytes::make(1, sign_response.to_byte()), ssh_string(ssh_sign(m, k, data, flags))]))
      }
    }
    None
  })() catch {
    // A malformed message: fails as any other.
    _ => None
  }
  match answered {
    Some(a) => a
    None => Bytes::make(1, agent_failure.to_byte())
  }
}

///|
/// Serves the agent on `path` (a Unix socket) until closed: what it gives closes it.
pub async fn serve_agent(m : Machine, path : String, k : SshKey, allowed : () -> Bool) -> () -> Unit {
  let held : Map[Int, Bytes] = Map([])
  (m.unix_serve)(path, async fn(conn, chunk) {
    let mut all = concat(held.get(conn).unwrap_or(b""), chunk)
    let out = Buffer()
    while all.length() >= 4 {
      let n = (all[0].to_int() << 24) | (all[1].to_int() << 16) | (all[2].to_int() << 8) | all[3].to_int()
      if n < 0 || n > 256 * 1024 {
        held.remove(conn)
        return (out.to_bytes(), true)
      }
      if all.length() < 4 + n {
        break
      }
      let reply = agent_answer(m, k, sub(all, 4, 4 + n), allowed)
      all = sub(all, 4 + n, all.length())
      out.write_bytes(u32(reply.length()))
      out.write_bytes(reply)
    }
    held[conn] = all
    (out.to_bytes(), false)
  })
}
