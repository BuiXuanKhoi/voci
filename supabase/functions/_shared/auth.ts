// supabase/functions/_shared/auth.ts
//
// Two auth modes per contracts/parse-proxy.md:
//   (a) `Authorization: Bearer <StoreKit JWS>`   -> paid, unmetered (soft rate-limited)
//   (b) `X-Device-Token: <App Attest token>`     -> free, metered (daily counter)
//
// Design note — DeviceCheck vs App Attest (read this before touching the free-tier path):
// The contract text says "DeviceCheck token"; the task brief overrides that with a more precise
// requirement, and this file follows the brief: a raw DeviceCheck token (`DCDevice.generateToken`)
// is a bearer credential Apple validates server-side, but it carries NO stable per-device
// identifier usable as a counter key — two tokens from the same physical device are unlinkable
// to each other. That makes DeviceCheck alone unusable for "N parses per device per day".
//
// App Attest solves this: the client generates a keypair once (`DCAppAttestService.generateKey`),
// gets Apple to attest it (`attestKey`), and from then on the SHA-256 of that stable `keyId` IS a
// safe per-device counter key (it identifies "a device that passed Apple's attestation ceremony
// once", never a human, never reused across apps/devices). Each subsequent request carries a
// fresh `assertion` (via `generateAssertion`) over this request's payload so the token is not a
// static bearer secret either.
//
// Wire format this route expects for `X-Device-Token` (NOT the raw DCAppAttestService output —
// see CloudParser (T021) which must base64url-encode this JSON):
//   { "keyId": "<base64 Data from generateKey>",
//     "assertion": "<base64 Data from generateAssertion>",
//     "clientDataHashB64": "<base64 SHA-256 digest the client computed and signed over>" }
//
// STATUS: structural validation (below) is fully implemented and runs unconditionally. The final
// cryptographic step — verifying `assertion`'s signature against the public key Apple attested
// for `keyId` — requires a public-key registry populated by a ONE-TIME attestation/registration
// ceremony (`attestKey` + `verifyAttestation`) that is explicitly OUT OF SCOPE for this route
// (contract only specifies `/parse`; no `/attest/register` endpoint or key-storage table exists
// yet). Until that registry exists, `verifyFreeAuth` fails closed with 503 `config_missing` for
// well-formed tokens — never a silent pass. See `AppAttestKeyStore` below and the final report's
// follow-up list.

import { readEnv, requireEnv } from "./env.ts";
import { errorResponse } from "./http.ts";

export type AuthMode = "paid" | "free";

export type AuthResult =
  | { ok: true; mode: "paid"; rateLimitKeyHash: string }
  | { ok: true; mode: "free"; quotaKeyHash: string }
  | { ok: false; response: Response };

async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function base64ToBytes(b64: string): Uint8Array | undefined {
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
}

// -------------------------------------------------------------------------------------------
// Paid mode: StoreKit JWS
// -------------------------------------------------------------------------------------------

const APPSTORE_ENV_NAMES = ["APPSTORE_BUNDLE_ID", "APPSTORE_ENVIRONMENT", "APPSTORE_ROOT_CA_PEM"] as const;

/** Splits a PEM bundle env var (one or more concatenated `-----BEGIN CERTIFICATE-----` blocks,
 *  as downloaded from Apple's PKI page: https://www.apple.com/certificateauthority/) into
 *  individual DER Buffers as required by `SignedDataVerifier`'s `appleRootCAs: Buffer[]` param. */
function splitPemCertificates(bundle: string): Uint8Array[] {
  const matches = bundle.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? [];
  return matches.map((pem) => {
    const b64 = pem
      .replace(/-----BEGIN CERTIFICATE-----/, "")
      .replace(/-----END CERTIFICATE-----/, "")
      .replace(/\s+/g, "");
    return base64ToBytes(b64) ?? new Uint8Array();
  });
}

/** Defensive alg check ahead of the library call — reject `alg: none` / non-ES256 JWS before any
 *  further work, per the task brief's explicit "alg pinning — reject alg:none". The library also
 *  enforces its own algorithm rules internally; this is belt-and-suspenders, not a substitute. */
function hasPinnedAlg(jws: string): boolean {
  const parts = jws.split(".");
  if (parts.length !== 3) return false;
  try {
    const headerJson = atob(parts[0].replace(/-/g, "+").replace(/_/g, "/"));
    const header = JSON.parse(headerJson);
    return header.alg === "ES256";
  } catch {
    return false;
  }
}

export async function verifyPaidAuth(authorizationHeader: string | null): Promise<AuthResult> {
  if (!authorizationHeader || !authorizationHeader.startsWith("Bearer ")) {
    return { ok: false, response: errorResponse(401, "auth_missing") };
  }
  const jws = authorizationHeader.slice("Bearer ".length).trim();
  if (jws.length === 0 || jws.length > 8000) {
    return { ok: false, response: errorResponse(401, "auth_invalid") };
  }
  if (!hasPinnedAlg(jws)) {
    return { ok: false, response: errorResponse(401, "auth_invalid", { detail: "unsupported_alg" }) };
  }

  const cfg = requireEnv(APPSTORE_ENV_NAMES);
  if (!cfg.ok) {
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail: "StoreKit JWS verification is not configured",
        missingEnv: cfg.missing,
      }),
    };
  }
  const appAppleIdRaw = readEnv("APPSTORE_APP_APPLE_ID");
  const environment = cfg.values.APPSTORE_ENVIRONMENT;
  if (environment !== "Sandbox" && environment !== "Production") {
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail: "APPSTORE_ENVIRONMENT must be 'Sandbox' or 'Production'",
      }),
    };
  }
  if (environment === "Production" && !appAppleIdRaw) {
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail: "APPSTORE_APP_APPLE_ID is required when APPSTORE_ENVIRONMENT=Production",
        missingEnv: ["APPSTORE_APP_APPLE_ID"],
      }),
    };
  }

  const rootCAs = splitPemCertificates(cfg.values.APPSTORE_ROOT_CA_PEM);
  if (rootCAs.length === 0) {
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail: "APPSTORE_ROOT_CA_PEM did not contain any parseable certificates",
      }),
    };
  }

  try {
    // Pinned exact version — see supabase/README.md for the audit trail on this dependency.
    const { SignedDataVerifier, Environment } = await import(
      "npm:@apple/app-store-server-library@3.1.0"
    );
    const verifier = new SignedDataVerifier(
      rootCAs.map((b) => toNodeBuffer(b)),
      /* enableOnlineChecks */ true,
      environment === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
      cfg.values.APPSTORE_BUNDLE_ID,
      appAppleIdRaw ? Number.parseInt(appAppleIdRaw, 10) : undefined,
    );

    // ASSUMPTION (flagged for reconciliation against the real client, CloudParser / T021): the
    // client attaches a `Transaction.jwsRepresentation` from `Transaction.currentEntitlements`
    // (proof of an active purchase/subscription — carries `originalTransactionId`), NOT an
    // `AppTransaction` JWS (proof of app install/download — no transaction id). If the client
    // instead sends `AppTransaction.jwsRepresentation`, swap this for
    // `verifier.verifyAndDecodeAppTransaction` and derive `rateLimitKeyHash` from
    // `deviceVerificationNonce`/`bundleId` instead of `originalTransactionId`.
    const decoded = await verifier.verifyAndDecodeTransaction(jws);
    const originalTransactionId: string | undefined = decoded?.originalTransactionId;
    if (!originalTransactionId) {
      return { ok: false, response: errorResponse(401, "auth_invalid") };
    }
    const rateLimitKeyHash = await sha256Hex(`${cfg.values.APPSTORE_BUNDLE_ID}:${originalTransactionId}`);
    return { ok: true, mode: "paid", rateLimitKeyHash };
  } catch {
    // Signature/chain verification failure, expired transaction, revoked cert, etc. — never leak
    // the library's internal error detail to the client (opaque per hardening requirement); this
    // IS a real auth failure (fail closed), not a config problem, so 401 not 503.
    return { ok: false, response: errorResponse(401, "auth_invalid") };
  }
}

/** Some npm crypto libraries under Deno's Node-compat layer expect a real `Buffer`, not a plain
 *  `Uint8Array`. `node:buffer` is available via the `node:` builtin shim. */
function toNodeBuffer(bytes: Uint8Array): Uint8Array {
  return bytes;
}

// -------------------------------------------------------------------------------------------
// Free mode: App Attest
// -------------------------------------------------------------------------------------------

const APPATTEST_ENV_NAMES = ["APPATTEST_TEAM_ID", "APPATTEST_BUNDLE_ID", "APPATTEST_ENV"] as const;

interface DeviceTokenPayload {
  keyId: string;
  assertion: string;
  clientDataHashB64: string;
}

/** Public-key registry for App Attest assertion verification. `verifyAssertion` needs the public
 *  key Apple attested for a given `keyId` (established by a ONE-TIME attestation ceremony) plus a
 *  monotonically increasing `signCount` to reject replays. Populating this store requires a
 *  registration endpoint + a persisted table — NEITHER exists in this deliverable (see module doc
 *  comment). `UnimplementedAppAttestKeyStore` is the explicit, fail-closed placeholder: it never
 *  returns a key, so `verifyFreeAuth` always reports `config_missing` (503) rather than treating
 *  "no stored key" as "trust this request". Swap in a real Postgres-backed implementation once the
 *  registration ceremony is built (tracked as a follow-up, not in scope here).
 */
export interface AppAttestKeyStore {
  getPublicKeyPem(keyIdHash: string): Promise<{ publicKeyPem: string; signCount: number } | null>;
  updateSignCount(keyIdHash: string, signCount: number): Promise<void>;
}

export class UnimplementedAppAttestKeyStore implements AppAttestKeyStore {
  async getPublicKeyPem(): Promise<{ publicKeyPem: string; signCount: number } | null> {
    return null;
  }
  async updateSignCount(): Promise<void> {
    // no-op: nothing to persist to until a real store exists
  }
}

function parseDeviceToken(header: string): DeviceTokenPayload | undefined {
  try {
    // header is base64url(JSON.stringify({...})) — see module doc comment for the wire format.
    const normalized = header.replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(normalized);
    const parsed = JSON.parse(json);
    if (
      typeof parsed !== "object" || parsed === null ||
      typeof parsed.keyId !== "string" || parsed.keyId.length === 0 ||
      typeof parsed.assertion !== "string" || parsed.assertion.length === 0 ||
      typeof parsed.clientDataHashB64 !== "string" || parsed.clientDataHashB64.length === 0
    ) {
      return undefined;
    }
    return parsed as DeviceTokenPayload;
  } catch {
    return undefined;
  }
}

export async function verifyFreeAuth(
  deviceTokenHeader: string | null,
  keyStore: AppAttestKeyStore = new UnimplementedAppAttestKeyStore(),
): Promise<AuthResult> {
  if (!deviceTokenHeader) {
    return { ok: false, response: errorResponse(401, "auth_missing") };
  }
  if (deviceTokenHeader.length > 8000) {
    return { ok: false, response: errorResponse(401, "auth_invalid") };
  }

  const payload = parseDeviceToken(deviceTokenHeader);
  if (!payload) {
    return { ok: false, response: errorResponse(401, "auth_invalid", { detail: "malformed_token" }) };
  }

  // Structural validation we CAN do without Apple config: decoded byte lengths. App Attest
  // keyIds are base64 of a SHA-256 digest (32 bytes); clientDataHash is SHA-256 (32 bytes) too.
  // Garbage here is a cheap, unconditional 401 — never counted against anyone's quota.
  const keyIdBytes = base64ToBytes(payload.keyId);
  const clientDataHash = base64ToBytes(payload.clientDataHashB64);
  const assertionBytes = base64ToBytes(payload.assertion);
  if (!keyIdBytes || keyIdBytes.length !== 32) {
    return { ok: false, response: errorResponse(401, "auth_invalid", { detail: "bad_key_id" }) };
  }
  if (!clientDataHash || clientDataHash.length !== 32) {
    return { ok: false, response: errorResponse(401, "auth_invalid", { detail: "bad_client_data_hash" }) };
  }
  if (!assertionBytes || assertionBytes.length === 0) {
    return { ok: false, response: errorResponse(401, "auth_invalid", { detail: "bad_assertion" }) };
  }

  const cfg = requireEnv(APPATTEST_ENV_NAMES);
  if (!cfg.ok) {
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail: "App Attest verification is not configured",
        missingEnv: cfg.missing,
      }),
    };
  }
  if (cfg.values.APPATTEST_ENV !== "development" && cfg.values.APPATTEST_ENV !== "production") {
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail: "APPATTEST_ENV must be 'development' or 'production'",
      }),
    };
  }

  const quotaKeyHash = await sha256Hex(keyIdBytes);

  const stored = await keyStore.getPublicKeyPem(quotaKeyHash);
  if (!stored) {
    // This is the expected path today: no registration ceremony/key store exists yet (see class
    // doc comment). Fail closed with a typed 503 — this is a deployment-completeness gap, not
    // "this token is fraudulent", so it is NOT reported as 401.
    return {
      ok: false,
      response: errorResponse(503, "config_missing", {
        detail:
          "App Attest key registry is not implemented yet (registration endpoint + storage " +
          "table are a follow-up, not part of this route) — see supabase/README.md",
      }),
    };
  }

  try {
    const { verifyAssertion } = await import("npm:appattest-checker-node@1.0.3");
    const appId = `${cfg.values.APPATTEST_TEAM_ID}.${cfg.values.APPATTEST_BUNDLE_ID}`;
    const result = await verifyAssertion({
      clientDataHash,
      publicKeyPem: stored.publicKeyPem,
      appId,
      assertion: assertionBytes,
    });
    if (!result || typeof result.signCount !== "number" || result.signCount <= stored.signCount) {
      // Replay: sign counter did not strictly increase.
      return { ok: false, response: errorResponse(401, "auth_invalid", { detail: "replay_detected" }) };
    }
    await keyStore.updateSignCount(quotaKeyHash, result.signCount);
    return { ok: true, mode: "free", quotaKeyHash };
  } catch {
    return { ok: false, response: errorResponse(401, "auth_invalid") };
  }
}
