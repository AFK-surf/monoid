# Mesh transport

- This crate carries encrypted endpoint packets. It grants no application access.
- Private endpoints use the caller's admitted scope directory. Public transit receives only authenticated direct
  neighbors and bounded identity proofs for active paths; a self-signature never grants workspace access.
- Keep routing decisions independent of sockets and wall time. Test them with an explicit clock.
- Bound packets, queues, route searches, paths, and reassembly before allocation.
- The outer endpoint must never use this transport to reach a neighbor.
- Keep network tests in `tests/` as ignored side tests. Unit tests use no real sockets or sleeps.
