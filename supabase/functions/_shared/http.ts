// supabase/functions/_shared/http.ts
//
// Small response helpers so every error path returns the same JSON shape and nothing ever
// serializes an upstream error body or an internal exception message back to the client
// (opaque-5xx requirement in the task brief / contract "5xx -> fallback, no user-visible error").

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" } as const;

export function jsonResponse(status: number, body: unknown, extraHeaders?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...(extraHeaders ?? {}) },
  });
}

/** Every typed error this API can return. `reason` values are stable strings a client can branch
 *  on (contract only documents "quota" for 429, but the others are additive/defensive — the
 *  client's documented behavior is "any non-200/429/401 -> fallback", so extra 4xx/5xx reasons
 *  are safe to add without breaking the contract). */
export type ApiErrorReason =
  | "method_not_allowed"
  | "unsupported_media_type"
  | "payload_too_large"
  | "invalid_json"
  | "invalid_request"
  | "auth_missing"
  | "auth_invalid"
  | "quota"
  | "rate_limited"
  | "config_missing"
  | "upstream_error"
  | "internal_error";

export function errorResponse(
  status: number,
  reason: ApiErrorReason,
  extra?: Record<string, unknown>,
): Response {
  return jsonResponse(status, { reason, ...(extra ?? {}) });
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
