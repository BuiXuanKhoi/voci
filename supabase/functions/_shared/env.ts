// supabase/functions/_shared/env.ts
//
// Small typed helper around Deno.env so every "is this deployment configured?" check happens in
// one place and looks the same everywhere. The whole point: NEVER let a missing secret silently
// fall through as "unauthenticated but allowed" — every auth/config gap must surface as a typed
// 503, never a bypass. See auth.ts for how this is used.

/** Reads a required env var; returns `undefined` (never throws) so callers can compose a single
 *  "what's missing" list and return one 503 that names every missing key at once. */
export function readEnv(name: string): string | undefined {
  const v = Deno.env.get(name);
  return v && v.length > 0 ? v : undefined;
}

export function readEnvInt(name: string, fallback: number): number {
  const raw = readEnv(name);
  if (raw === undefined) return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/** Collects every named env var; if any are missing, returns the missing list instead of values
 *  so the caller can produce a single explicit 503 naming exactly what an operator needs to set. */
export function requireEnv<K extends string>(
  names: readonly K[],
): { ok: true; values: Record<K, string> } | { ok: false; missing: K[] } {
  const values = {} as Record<K, string>;
  const missing: K[] = [];
  for (const name of names) {
    const v = readEnv(name);
    if (v === undefined) missing.push(name);
    else values[name] = v;
  }
  if (missing.length > 0) return { ok: false, missing };
  return { ok: true, values };
}
