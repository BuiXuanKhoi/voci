// supabase/functions/_shared/http.ts
//
// Small response helpers so every error path returns the same JSON shape and nothing ever
// serializes an upstream error body, an internal exception message, an env var name, or "which
// check failed" back to the client (opaque-error requirement in
// specs/002-workflow-command-center/contracts/account-auth.md §5).
//
// Wire shape (contract §5, CHỐT): every error body is `{"error":"<code>"}`, optionally with
// `resetAt` on a 429. `<code>` is drawn ONLY from `ApiErrorCode` below — that list is exhaustive
// per the contract; do not invent new codes or leak extra fields (the old free-tier branch used
// to return `detail`/`missingEnv` alongside `reason` — that leak is gone on purpose, don't bring
// it back).

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" } as const;

export function jsonResponse(status: number, body: unknown, extraHeaders?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...(extraHeaders ?? {}) },
  });
}

/** Exhaustive per contract §5. HTTP status pairing per the contract table:
 *    auth_missing 401 · auth_invalid 401 · upgrade_required 403 · quota_exceeded 429 ·
 *    rate_limited 429 · subscription_already_linked 409 · invalid_request 400 ·
 *    payload_too_large 413 · upstream_error 502 · service_unavailable 503.
 *  Routing/method/content-type rejections that predate this list (405 wrong method, 404 wrong
 *  path, 415 wrong content-type, 400 bad JSON) are NOT their own codes — they all collapse onto
 *  `invalid_request` in the body while keeping whatever HTTP status is actually accurate for the
 *  situation; only the JSON `error` field is restricted to this list, not the HTTP status code
 *  itself. Likewise any last-resort/unhandled-exception path reports `service_unavailable` (503)
 *  rather than a bespoke `internal_error`, since that code no longer exists in the contract. */
export type ApiErrorCode =
  | "auth_missing"
  | "auth_invalid"
  | "upgrade_required"
  | "quota_exceeded"
  | "rate_limited"
  | "subscription_already_linked"
  | "invalid_request"
  | "payload_too_large"
  | "upstream_error"
  | "service_unavailable";

/** `extra` is deliberately narrow (only `resetAt`, only meaningful on a 429) — this signature
 *  shape makes it structurally hard to accidentally widen an error body with a leaky field at a
 *  call site later. */
export function errorResponse(
  status: number,
  code: ApiErrorCode,
  extra?: { resetAt?: string },
): Response {
  return jsonResponse(status, { error: code, ...(extra ?? {}) });
}

export class BodyTooLargeError extends Error {}

/** Streams the request body and aborts the moment it exceeds `maxBytes`, instead of buffering an
 *  arbitrarily large body into memory before checking its length (a `Content-Length` header can
 *  be absent or wrong under chunked transfer-encoding, so it cannot be trusted alone — this is
 *  the actual enforcement, `Content-Length` is only a fast-path hint). Part of the DoS hardening
 *  requirement (body size cap) in the task brief. */
export async function readBodyCapped(req: Request, maxBytes: number): Promise<string> {
  const contentLength = req.headers.get("content-length");
  if (contentLength && Number.parseInt(contentLength, 10) > maxBytes) {
    throw new BodyTooLargeError();
  }
  if (!req.body) return "";

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new BodyTooLargeError();
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(merged);
}

/** Byte-accurate sibling of `readBodyCapped` for binary/multipart bodies (audio uploads), where
 *  decoding through `TextDecoder` (as the text variant does) would corrupt non-UTF-8 bytes. Same
 *  enforcement model: `Content-Length` is checked first as a fast-path hint, but the real bound is
 *  the streaming byte counter below, so a missing/understated `Content-Length` under chunked
 *  transfer-encoding still cannot smuggle an oversized body past this check — used by the `groq`
 *  function's multipart passthrough (see supabase/functions/groq/index.ts). */
export async function readBodyCappedBytes(req: Request, maxBytes: number): Promise<Uint8Array> {
  const contentLength = req.headers.get("content-length");
  if (contentLength && Number.parseInt(contentLength, 10) > maxBytes) {
    throw new BodyTooLargeError();
  }
  if (!req.body) return new Uint8Array(0);

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new BodyTooLargeError();
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return merged;
}
