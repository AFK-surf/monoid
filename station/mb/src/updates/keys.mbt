// keys.ts: the keys still.fail's releases are signed with (scripts/release-sign.ts), raw Ed25519 public keys in base64:
// the release key (CI's `production` environment, RELEASE_SIGNING_KEY) and a recovery key kept offline.

///|
pub let release_keys : Array[String] = [
  // release-1 (id 3c2d0f7ad7f9eca2): CI's RELEASE_SIGNING_KEY; its private key also kept in 1Password.
  "vJeYSXYJW04ANrn49w+I7nzS/8NFsh1MKwRCiJ8PVPI=",
  // recovery (id d3353d225efaaecd): kept offline (1Password) only, never in CI; signs a release that replaces release-1 should it be lost.
  "pvYJzkDfZGPRIPSLQ0jQDTXwhkwfbMsUtXxdVavugxc=",
]
