// Public Suffix List (PSL) and secure-origin checks for browser sign-ins, autofill, and WebAuthn relying parties.
// Uses tldts with private domains enabled (e.g. github.io, vercel.app, s3.amazonaws.com) so a shared hosting suffix is
// never treated as a single site or relying party.
import { parse } from "tldts";

const PSL_OPTIONS = { allowPrivateDomains: true } as const;

/// Normalizes a hostname (or cookie domain with leading dot, trailing dot, or IDN labels) into lowercase ASCII form.
/// Rejects strings containing URL delimiters, credentials, whitespace, or non-IPv6 colons. Returns "" when invalid.
export function normalizeHost(host: string): string {
  const stripped = host.trim().toLowerCase().replace(/^\.+/, "").replace(/\.+$/, "");
  if (stripped === "" || /[/?#@\\\s]/.test(stripped)) return "";
  if (stripped.includes(":")) {
    if (!/^\[?[0-9a-f:]+\]?$/.test(stripped)) return "";
    const bare = stripped.startsWith("[") && stripped.endsWith("]") ? stripped.slice(1, -1) : stripped;
    try {
      return new URL(`http://[${bare}]`).hostname;
    } catch {
      return "";
    }
  }
  try {
    return new URL(`http://${stripped}`).hostname.replace(/\.+$/, "");
  } catch {
    return "";
  }
}

/// Whether `host` is a public suffix (ICANN or private PSL entry such as `co.uk` or `github.io`).
export function isPublicSuffix(host: string): boolean {
  const h = normalizeHost(host);
  if (h === "") return false;
  const parsed = parse(h, PSL_OPTIONS);
  return (parsed.isIcann === true || parsed.isPrivate === true) && parsed.domain === null && parsed.publicSuffix !== null;
}

/// The registrable domain (eTLD+1) of `host` under the PSL (private domains included), or null if none (public suffix,
/// IP address, localhost, or invalid host).
export function registrableDomain(host: string): string | null {
  const h = normalizeHost(host);
  if (h === "") return null;
  const parsed = parse(h, PSL_OPTIONS);
  if (parsed.isIp || parsed.domain === null) return null;
  return parsed.domain;
}

/// Whether `host` belongs to `site` (exact host or subdomain) without crossing a nested private PSL boundary
/// (for example `bucket.s3.amazonaws.com` does not match `amazonaws.com` because `s3.amazonaws.com` is a private suffix).
export function sameSiteHost(host: string, site: string): boolean {
  const h = normalizeHost(host);
  const s = normalizeHost(site);
  if (h === "" || s === "" || isPublicSuffix(s)) return false;
  if (h !== s && !h.endsWith(`.${s}`)) return false;
  const siteReg = registrableDomain(s);
  if (siteReg !== null && registrableDomain(h) !== siteReg) return false;
  return true;
}

/// Whether `host` is a local loopback host (`localhost`, `127.0.0.1`, or `[::1]` / `::1`).
export function isLoopbackHost(host: string): boolean {
  const h = normalizeHost(host);
  return h === "localhost" || h === "127.0.0.1" || h === "[::1]";
}

/// Whether `url` is a secure origin eligible for autofill, login prompts, and WebAuthn: `https:` or loopback `http:`.
export function isSecureAutofillUrl(url: string): boolean {
  try {
    const u = new URL(url);
    if (u.protocol === "https:") return u.hostname !== "";
    if (u.protocol === "http:") return isLoopbackHost(u.hostname);
    return false;
  } catch {
    return false;
  }
}
