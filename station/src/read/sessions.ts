// A session's files as its routes answer them (api/routes/sessions.ts): what kind a file is, and why it did not read.
// The pages' reads of sessions and threads, ported from the Rust station's admin/views.rs, are the tests'
// (test/reference/sessions.ts).
import { basename } from "node:path";

// ---- a session's files ----

/// files.rs `mime`: by the file's extension.
export function mime(path: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  // Path::extension: none for a name with no dot, or only the one it starts with.
  const ext = dot <= 0 ? null : name.slice(dot + 1).toLowerCase();
  const kinds: Record<string, string> = {
    png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", svg: "image/svg+xml",
    pdf: "application/pdf", txt: "text/plain; charset=utf-8", md: "text/markdown; charset=utf-8", json: "application/json",
  };
  return (ext !== null && Object.hasOwn(kinds, ext) ? kinds[ext] : undefined) ?? "application/octet-stream";
}

/// std::io::Error as anyhow shows it.
export function ioMessage(e: NodeJS.ErrnoException): string {
  const said: Record<string, string> = { ENOENT: "No such file or directory", EACCES: "Permission denied", EISDIR: "Is a directory", EPERM: "Operation not permitted" };
  return e.code && said[e.code] && typeof e.errno === "number" ? `${said[e.code]} (os error ${-e.errno})` : e.message;
}
