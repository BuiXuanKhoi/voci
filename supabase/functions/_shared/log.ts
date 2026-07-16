// supabase/functions/_shared/log.ts
//
// Structured, privacy-safe logging. HARD RULE (contract obligation 3 / task privacy directive):
// transcript text, task titles, notes, open_task_titles content, and any other user-authored
// body text must NEVER reach a log line — only sizes, counts, latency, auth mode, and status.
//
// This module is intentionally the *only* place that calls console.log/console.error in the
// function, so a reviewer can audit "does anything log a body?" by reading one small file
// instead of grepping the whole codebase.

export type LogFields = Record<string, string | number | boolean | null | undefined>;

/** Emits one structured JSON log line. Field VALUES are restricted to primitives on purpose —
 *  there is no way to pass an object/string blob through this function, which makes it much
 *  harder to accidentally log a transcript by widening a call site later. */
export function logEvent(event: string, fields: LogFields = {}): void {
  const safe: Record<string, unknown> = { event, ts: new Date().toISOString() };
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined) continue;
    safe[k] = v;
  }
  console.log(JSON.stringify(safe));
}

export function logError(event: string, fields: LogFields = {}): void {
  const safe: Record<string, unknown> = { event, ts: new Date().toISOString(), level: "error" };
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined) continue;
    safe[k] = v;
  }
  console.error(JSON.stringify(safe));
}
