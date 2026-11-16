// The station's queue for other stations' tasks (station_task, jobs/remote.ts) is the MoonBit program's
// (mb/src/reader/admit.mbt says what decides which task starts and when, and jobs.mbt runs it). What of it the station
// names here: what the system says of its memory and why a task waits (how often the queue looks while one waits is
// jobs.mbt's `look_ms`).

/// What the system says of its memory: under pressure (high), or about to run out (critical); null where it cannot be
/// read.
export type Pressure = "normal" | "high" | "critical";

/// Why a task waits, for its agent (station_task's answer): the memory under pressure, the small tasks' slot taken, the
/// screen another task's, or a person's.
export type Why = "memory" | "small" | "screen" | "person";
