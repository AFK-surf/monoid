// What of the machine the vault's commands need and the program does not do itself (station/src/vault/run.ts,
// proxy.ts, ssh-agent.ts, x509.ts's node:crypto, node:fs, node:net, node:tls and child_process): a command started in a
// group of its own and followed to its end, files written for it alone, the keys the proxy's certificates and an SSH
// agent sign with, and the sockets they are served on. Only the I/O and the primitives: what is decided (which run a
// proxy's credentials name, whether a host is opened, what a header becomes, what an agent answers, what a
// certificate says, what a command's output reads as) is the program's, in run.mbt, proxy.mbt, ssh_agent.mbt and
// x509.mbt. Node answers these when running under Node; a station that is only the program answers them by its shell.

///|
/// A command to start (run.ts `startCommand`): `shell -c command` in `cwd` with `env` alone, in a group of its own,
/// killed whole (SIGKILL) after `timeout_ms`; each chunk of its stdout and stderr told as it comes.
pub(all) struct Spawn {
  shell : String
  args : Array[String]
  cwd : String
  env : Array[(String, String)]
  timeout_ms : Double
  on_out : (Bytes) -> Unit
  on_err : (Bytes) -> Unit
}

///|
/// How a command ended: its code or signal, whether it was stopped for its time, or why it never started.
pub(all) struct Ended {
  code : Int?
  signal : String?
  timed_out : Bool
  /// It did not start: why (`could not start <shell>: …`).
  error : String?
}

///|
/// A private key the machine holds (a P-256 key of the proxy's, an SSH key), by a handle the program names it by.
pub(all) struct KeyRef {
  handle : String
  /// Its kind: `p256`, `ed25519`, `rsa`.
  kind : String
  /// Its public half: a P-256 point `04‖x‖y`; an Ed25519 key's 32 bytes; an RSA key's `e` and `n` (big-endian).
  public : Array[Bytes]
}

///|
/// A CONNECT to the proxy: its target as asked and its credentials (`proxy-authorization`).
pub(all) struct ConnectAsk {
  url : String
  authorization : String?
}

///|
/// What the proxy does with a CONNECT: answers it and closes (`HTTP/1.1 407 …`), passes it through to a host as it
/// is, or opens it with a certificate for its host (its TLS context, the program's handle) and serves each request in it.
pub(all) enum ConnectDecision {
  Refuse(String)
  Tunnel(String, Int)
  Open(String, Int, String, Int)
}

///|
/// One request in an opened HTTPS connection: its method, path and headers (each with all its values).
pub(all) struct ForwardAsk {
  run : Int
  host : String
  port : Int
  verb : String
  path : String
  headers : Array[(String, Array[String])]
}

///|
/// What is done with it: refused (`403 grant expired`), or sent on with these headers (the CA roots the host's own
/// certificate is checked against: the machine's, or a test's).
pub(all) enum ForwardDecision {
  Forbid(Int, String)
  Forward(Array[(String, Array[String])])
}

///|
/// The machine as the vault's commands use it.
pub(all) struct Machine {
  /// A new directory under the machine's temporary one (`mkdtemp(join(tmpdir(), prefix))`).
  temp_dir : async (String) -> String
  /// A path removed, with what is under it (`rm -rf`).
  remove : async (String) -> Unit
  chmod : async (String, Int) -> Unit
  /// Bytes written to a path, made with this mode.
  write_file : async (String, Bytes, Int) -> Unit
  /// A file read, None where there is none.
  read_file : async (String) -> Bytes?
  /// A directory made with its parents (`mkdir -p`), with this mode.
  mkdir : async (String, Int) -> Unit
  /// The shell a command is run by (platform.posixShellSoon), found by this environment; raises what to do where none.
  shell_for : async (Array[(String, String)]) -> String
  /// A command run to its end.
  spawn : async (Spawn) -> Ended
  /// A new P-256 key.
  p256_new : async () -> KeyRef
  /// A private key from its PEM (PKCS#8, SEC1, PKCS#1 or an OpenSSH key's parts made PEM): None where it is none.
  key_of_pem : async (String) -> KeyRef?
  /// An Ed25519 key from its 32-byte seed.
  ed25519_of_seed : async (Bytes) -> KeyRef
  /// An RSA key from its JWK's parts (`n`, `e`, `d`, `p`, `q`, `dp`, `dq`, `qi`, base64url).
  rsa_of_jwk : async (Json) -> KeyRef
  /// A key's PKCS#8 PEM.
  key_pem : async (KeyRef) -> String
  /// A signature: ECDSA's DER over SHA-256 (`p256`), Ed25519's, or RSA PKCS#1 v1.5 with `hash` (sha1, sha256, sha512).
  sign : async (KeyRef, String, Bytes) -> Bytes
  /// The SHA-1 of bytes (a key's identifier).
  sha1 : async (Bytes) -> Bytes
  /// The machine's root certificates (`tls.rootCertificates`), PEM.
  roots : async () -> Array[String]
  /// A TLS context of this key and certificate chain (PEM): its handle.
  tls_context : async (String, String) -> String
  /// The proxy listening on 127.0.0.1 (any free port), each CONNECT decided and each opened request decided by these:
  /// its port.
  proxy_listen : async (async (ConnectAsk) -> ConnectDecision, async (ForwardAsk) -> ForwardDecision) -> Int
  proxy_close : () -> Unit
  /// An SSH agent's socket served at a path: each connection's chunks told (its number), what to write back said, and
  /// whether the connection is destroyed after it. What it gives closes it.
  unix_serve : async (String, async (Int, Bytes) -> (Bytes, Bool)) -> () -> Unit
  /// Random bytes (`randomBytes`).
  random : (Int) -> Bytes
}
