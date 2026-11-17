// What the station's reading of a runtime's output shares with its other parts. The reading itself (each runtime's
// stream as live steps) is the MoonBit program's (mb/src/claude, mb/src/codex, mb/src/dsh, mb/src/cursor, mb/src/acp);
// what the TypeScript station made of it before is the tests' (test/reference/live.ts), which the program is held to.

/// At most `n` characters (Rust's chars().take(n)).
export const chars = (text: string, n: number): string => {
  if (text.length <= n) return text;
  return Array.from(text).slice(0, n).join("");
};
