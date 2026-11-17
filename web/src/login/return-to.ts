/** Where a page given `?return_to=` goes once signed in: a path of this origin, else its root. */
export function returnTo(query: string): string {
  const to = new URLSearchParams(query).get("return_to") ?? "/";
  if (!to.startsWith("/") || to.startsWith("//")) return "/";
  // Resolve as the browser does: a backslash or an ignored control character can turn a path into another host.
  const base = "https://return.invalid";
  try {
    const url = new URL(to, base);
    const path = url.pathname;
    if (url.origin !== base || path.startsWith("//") || path.startsWith("/auth/") || path.startsWith("/login")) return "/";
    return path + url.search + url.hash;
  } catch {
    return "/";
  }
}
