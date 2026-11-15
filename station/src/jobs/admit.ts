// The station's queue for other stations' tasks (station_task, jobs/remote.ts) is the MoonBit program's
// (mb/src/reader/admit.mbt says what decides which task starts and when, and jobs.mbt runs it). What of it the station
// names here: what the system says of its memory, how often the queue looks while a task waits, why a task waits.

/// What the system says of its memory: under pressure (high), or about to run out (critical); null where it cannot be
/// read.
export type Pressure = "normal" | "high" | "critical";

/// How often the queue looks at the machine (its memory, a person at it) while a task waits (jobs.mbt `look_ms`).
export const LOOK_MS = 5000;

/// Why a task waits, for its agent (station_task's answer): the memory under pressure, the small tasks' slot taken, the
/// screen another task's, or a person's.
export type Why = "memory" | "small" | "screen" | "person";
