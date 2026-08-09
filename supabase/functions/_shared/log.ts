// supabase/functions/_shared/log.ts
//
// Structured, privacy-safe logging. HARD RULE (contract obligation 3 / task privacy directive):
// transcript text, task titles, notes, open_task_titles content, and any other user-authored
// body text must NEVER reach a log line in the DEFAULT (production) configuration — only sizes,
// counts, latency, auth mode, and status. The ONE deliberate opt-in exception is
// `LOG_VERBOSE_BODIES=1` (see `verboseBodiesEnabled`/`truncateForLog` below), meant for a developer
// chasing a live bug on a non-production deployment; it MUST stay unset (or anything other than
// the literal string "1") on production, because turning it on puts real user transcript/task
// content into logs, which conflicts with what the App Store privacy label already declares.
//
// Regardless of that flag, some things are NEVER logged, under any configuration, by any helper in
// this file: `Authorization`/`apikey` header VALUES, any API key/secret (GROQ_API_KEY,
// GEMINI_API_KEY, StoreKit JWS, promo codes, ...), and raw audio bytes. Exceptions to the
// user-content rule are still made for is data that is diagnostic about OUR OWN system, not
// user-authored: an upstream service's own error-response body (e.g. Groq/Gemini's
// `"invalid_request_error: file too short"`) and a caught exception's own `message`/`stack` (our
// code's call frames, not user input) — both are safe to log unconditionally, truncated, and both
// exist specifically so a boundary bug never again looks like a silent, undiagnosable 400.
//
// This module is intentionally the *only* place that calls console.log/console.error in the
// function, so a reviewer can audit "does anything log a body?" by reading one small file
// instead of grepping the whole codebase.

import { readEnv } from "./env.ts";

export type LogFields = Record<string, string | number | boolean | null | undefined>;

/** Emits one structured JSON log line. Field VALUES are restricted to primitives on purpose —
 *  there is no way to pass an object/string blob through this function, which makes it much
 *  harder to accidentally log a transcript by widening a call site later.
 *
 *  `reqId`, when present in `fields`, is deliberately pulled out and placed right after `event` —
 *  every log line from one inbound request carries the SAME `reqId` (see `newRequestId` below), and
 *  a human scanning raw log output needs to be able to glance at the start of the line and see it,
 *  not hunt for it alphabetically among a dozen other fields. */
export function logEvent(event: string, fields: LogFields = {}): void {
  console.log(JSON.stringify(buildLogLine(event, fields)));
}

export function logError(event: string, fields: LogFields = {}): void {
  console.error(JSON.stringify(buildLogLine(event, fields, "error")));
}

function buildLogLine(event: string, fields: LogFields, level?: "error"): Record<string, unknown> {
  const { reqId, ...rest } = fields;
  const safe: Record<string, unknown> = { event };
  if (reqId !== undefined) safe.reqId = reqId;
  if (level) safe.level = level;
  safe.ts = new Date().toISOString();
  for (const [k, v] of Object.entries(rest)) {
    if (v === undefined) continue;
    safe[k] = v;
  }
  return safe;
}

/** Mints a fresh correlation id for one inbound request. THE reason logs are usable at all under
 *  concurrent traffic: without a shared id, the request-start/upstream-call/request-end lines for
 *  many simultaneous callers interleave in the log stream with no way to tell which lines belong
 *  together. Callers must generate exactly ONE of these per request, as the very first thing in
 *  the handler, and pass it through EVERY `logEvent`/`logError`/log-helper call for that request —
 *  including calls made from `_shared/` modules (auth, quota, appstore, gemini) on that request's
 *  behalf. Do NOT stash this in a module-level variable to avoid threading it through call sites —
 *  one function instance serves many concurrent requests, so a shared mutable "current request id"
 *  would let one caller's id leak onto another caller's log lines and produce a confidently wrong
 *  trace. Always pass it explicitly. `crypto.randomUUID()` is a Web Crypto standard already
 *  available in Deno's runtime with no import, and is derived from nothing about the caller (no
 *  privacy exposure of its own). */
export function newRequestId(): string {
  return crypto.randomUUID();
}

/** Reads the verbose-bodies opt-in flag. MUST be unset (or anything other than the literal string
 *  "1") on production — flipping it on is what allows `truncateForLog` output of REQUEST bodies to
 *  actually reach a log line (see the module doc comment above and each route's use of it). Goes
 *  through `readEnv` from `./env.ts` (not a bespoke `Deno.env.get` call) so this file's env access
 *  matches the one helper the rest of the codebase uses for "is this env var set". */
export function verboseBodiesEnabled(): boolean {
  return readEnv("LOG_VERBOSE_BODIES") === "1";
}

/** Truncates `text` to at most `max` characters for a log line, ALWAYS marking that a cut happened
 *  (`…(+N more)`) rather than silently emitting a partial string that looks complete — a reviewer
 *  scanning logs must be able to tell truncated output from a short body at a glance. Used both for
 *  verbose-mode request-body previews and for the always-on upstream-error-body / stack-trace
 *  logging (see module doc comment) — callers decide, by whether they gate the call behind
 *  `verboseBodiesEnabled()`, which category a given call site is; this function itself has no way
 *  to know or enforce that, since it deals in strings, not requests. */
export function truncateForLog(text: string, max = 500): string {
  if (text.length <= max) return text;
  return `${text.slice(0, max)}…(+${text.length - max} more)`;
}

/** Standard trio of fields to spread into a `logError` call from inside ANY `catch (err)` block in
 *  this codebase: `message`, `errorName` (the constructor name, e.g. "TypeError" or
 *  "GeminiUpstreamError"), and `stack` truncated to ~300 chars. All three describe OUR OWN code's
 *  exception — the message text and call frames of something that threw inside this deployment —
 *  never user-authored content, so they are safe to log unconditionally, NOT gated behind
 *  `verboseBodiesEnabled()`. Exists so a `catch` block can never silently swallow an error by
 *  omission: spread this instead of hand-rolling a partial (and easy to under-specify) subset. */
export function errorDetails(err: unknown): LogFields {
  const errorName = err instanceof Error
    ? err.constructor?.name ?? "Error"
    : (err as { constructor?: { name?: string } } | null)?.constructor?.name ?? typeof err;
  return {
    message: err instanceof Error ? err.message : String(err),
    errorName,
    stack: err instanceof Error && err.stack ? truncateForLog(err.stack, 300) : undefined,
  };
}

/** Point 1 of the 3 required log points ("the function was called"). Deliberately logs ONLY shapes
 *  and presence/absence, never values that could carry user data:
 *   - `route`/`method`: the request line itself, not user-controlled content.
 *   - `queryParamNames`: NAMES only, comma-joined — a query VALUE could carry user text in some
 *     future debug convenience; the name alone tells an operator what shape of request arrived.
 *   - `contentType`/`contentLength`/`userAgent`: standard request metadata, not body content.
 *   - `headerNames`: NAMES only, comma-joined — never header VALUES (that is exactly where
 *     `Authorization`/`apikey` live; see the next three fields for the one deliberate, safe
 *     exception carved out of that rule).
 *   - `hasAuthorization`/`authScheme`: whether a bearer credential was attached and what scheme it
 *     claims — useful for telling "client sent no token" apart from "client sent the wrong shape"
 *     without ever touching the token's bytes.
 *   - `authTokenLength`: the credential's LENGTH, not its value. A length cannot be replayed or used
 *     to authenticate as anyone; it is diagnostic only ("was a token even attached, roughly how big
 *     was it").
 *  `reqId` is required here (not just accepted via `fields`) because this is the anchor line —
 *  every later log line for this request is only traceable back to it if this one carries the id
 *  too. Call this as the very FIRST thing in a handler, before method/content-type/auth checks — an
 *  early-rejected request must still leave a trace (this is exactly what the undiagnosable-400
 *  boundary bug needed and didn't have). */
export function logRequestStart(req: Request, reqId: string, fields: LogFields = {}): void {
  const url = new URL(req.url);
  const authHeader = req.headers.get("authorization");
  const authScheme = authHeader ? authHeader.split(" ")[0] : undefined;
  const authTokenLength = authHeader
    ? authHeader.length - (authScheme ? authScheme.length + 1 : 0)
    : undefined;

  logEvent("request_start", {
    reqId,
    route: url.pathname,
    method: req.method,
    queryParamNames: [...url.searchParams.keys()].join(","),
    contentType: req.headers.get("content-type") ?? undefined,
    contentLength: req.headers.get("content-length") ?? undefined,
    userAgent: req.headers.get("user-agent") ?? undefined,
    headerNames: [...req.headers.keys()].join(","),
    hasAuthorization: authHeader !== null,
    authScheme,
    authTokenLength,
    ...fields,
  });
}

/** Point 2 (first half) of the 3 required log points — logged immediately BEFORE calling any
 *  external service. `url` is reduced to origin + pathname ONLY: a third-party URL's query string
 *  is exactly where an API key/token often rides (e.g. `?key=...`), so the query component is
 *  stripped before it is ever concatenated into a log line, regardless of what the caller passes
 *  in. When `url` isn't a parseable absolute URL (some underlying library — e.g. the App Store
 *  Server Library — makes its own HTTP calls without handing us a literal URL to redact), callers
 *  pass a constant, symbolic string instead (never raw user input) and it is logged as-is.
 *  `name` identifies which upstream this is (e.g. "groq", "gemini", "supabase_db",
 *  "appstore_verify") so multiple upstream calls in one request are distinguishable. */
export function logUpstreamRequest(
  name: string,
  url: string,
  method: string,
  fields: LogFields = {},
): void {
  let safeUrl: string;
  try {
    const parsed = new URL(url);
    safeUrl = `${parsed.origin}${parsed.pathname}`;
  } catch {
    safeUrl = url;
  }
  logEvent("upstream_request", { service: name, url: safeUrl, method, ...fields });
}

/** Point 2 (second half) — logged immediately AFTER an external service call returns (success or
 *  failure), pairing with `logUpstreamRequest` above via the same `reqId`/`service` name.
 *  `status`/`latencyMs` are transport-level facts about our own call. `fields` may ALSO carry a
 *  truncated upstream error-response body (via `truncateForLog`) when `status` is non-2xx — that is
 *  a deliberate, always-on exception to the "never log body content" rule: an upstream's OWN error
 *  diagnostic text (e.g. Groq/Gemini's `"invalid_request_error: file too short"`) is not
 *  user-authored content, it is the upstream's message about our request, and without it a 4xx from
 *  a third party is exactly as undiagnosable as the boundary bug that prompted this whole change.
 *  Never do this for a 2xx response — a successful body is the actual transcript/model output. */
export function logUpstreamResponse(
  name: string,
  status: number,
  latencyMs: number,
  fields: LogFields = {},
): void {
  logEvent("upstream_response", { service: name, status, latencyMs: Math.round(latencyMs), ...fields });
}

/** Point 3 of the 3 required log points — MUST be reached by every return path in a handler,
 *  including early rejections and the top-level catch-all, so a request can never vanish from the
 *  logs between its start line and some response actually being sent. `status`/`latencyMs` describe
 *  our own response, never its body. `fields.reason` is how one caller distinguishes "which branch
 *  fired" across the many possible early-exit points in a handler — pass a short, distinct string
 *  every time (e.g. `"invalid_method"`, `"quota_exceeded"`, `"upstream_non_ok"`) so two different
 *  400s never produce indistinguishable log lines. */
export function logRequestEnd(status: number, latencyMs: number, fields: LogFields = {}): void {
  logEvent("request_end", { status, latencyMs: Math.round(latencyMs), ...fields });
}
