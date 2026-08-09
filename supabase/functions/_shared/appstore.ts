// supabase/functions/_shared/appstore.ts
//
// App Store Server Library JWS verification — moved here from the old `_shared/auth.ts` (2026-07-26
// account-auth pivot, see specs/002-workflow-command-center/contracts/account-auth.md). StoreKit
// JWS is no longer a bearer credential for ANY route: it used to be sent as `Authorization: Bearer
// <jws>` and treated as proof of a paid caller on every request. Now it is submitted ONCE (and
// again on each renewal) to `POST /subscription/link`, which uses `verifyAppStoreJWS` below purely
// to answer "is this a real, current, Apple-signed transaction for our app?" — everything about
// WHO the caller is comes from `_shared/auth.ts`'s `verifyAccount` (Supabase Auth), not from this
// file. Keep this module's job narrow: JWS in, verified transaction facts out, nothing else.

import { Buffer } from "node:buffer";
import { readEnv, requireEnv } from "./env.ts";
import { errorDetails, logError } from "./log.ts";

const APPSTORE_ENV_NAMES = ["APPSTORE_BUNDLE_ID", "APPSTORE_ENVIRONMENT", "APPSTORE_ROOT_CA_PEM"] as const;

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

/** Splits a PEM bundle env var (one or more concatenated `-----BEGIN CERTIFICATE-----` blocks,
 *  as downloaded from Apple's PKI page: https://www.apple.com/certificateauthority/) into
 *  individual DER Buffers as required by `SignedDataVerifier`'s `appleRootCAs: Buffer[]` param. */
function splitPemCertificates(bundle: string): Uint8Array[] {
  const matches = bundle.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? [];
  // Unparseable blocks are dropped (not mapped to an empty Uint8Array) — an empty buffer would
  // silently satisfy `rootCAs.length === 0`'s emptiness guard below while contributing nothing
  // usable to `SignedDataVerifier`, defeating the guard. Only genuinely decoded certs count.
  return matches
    .map((pem) => {
      const b64 = pem
        .replace(/-----BEGIN CERTIFICATE-----/, "")
        .replace(/-----END CERTIFICATE-----/, "")
        .replace(/\s+/g, "");
      return base64ToBytes(b64);
    })
    .filter((bytes): bytes is Uint8Array => bytes !== undefined && bytes.length > 0);
}

/** Defensive alg check ahead of the library call — reject `alg: none` / non-ES256 JWS before any
 *  further work (alg pinning). The library also enforces its own algorithm rules internally; this
 *  is belt-and-suspenders, not a substitute. */
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

/** Some npm crypto libraries under Deno's Node-compat layer expect a real `Buffer`, not a plain
 *  `Uint8Array`. `node:buffer` is available via the `node:` builtin shim. */
function toNodeBuffer(bytes: Uint8Array): Buffer {
  return Buffer.from(bytes);
}

export interface VerifiedAppStoreTransaction {
  originalTransactionId: string;
  productId: string;
  expiresDate: string; // ISO8601, converted from the library's epoch-ms `expiresDate`
  bundleId: string;
}

export type AppStoreVerifyResult =
  | { ok: true; transaction: VerifiedAppStoreTransaction }
  | { ok: false; status: 401; code: "auth_invalid" }
  | { ok: false; status: 503; code: "service_unavailable" };

/** Verifies a StoreKit 2 `Transaction.jwsRepresentation` (from `Transaction.currentEntitlements` —
 *  proof of an active purchase/subscription, carries `originalTransactionId`) against Apple's
 *  official `@apple/app-store-server-library`. Fails closed: any missing/invalid config is a 503
 *  (deployment problem, not the caller's fault), any signature/chain/shape failure is a 401
 *  (real auth failure). Never throws. */
/** `reqId`, when passed, threads the caller's correlation id into every `logError` call this
 *  function makes — optional only so the signature doesn't break a hypothetical caller written
 *  before request-id tracing existed; the one real call site (`../subscription/index.ts`'s
 *  `handleLink`) passes it. Without this, a JWS verification failure — one of the higher-stakes
 *  failure modes in the whole system, since it gates who gets billed as Pro — would be exactly the
 *  kind of log line NOT traceable back to the request that produced it. */
export async function verifyAppStoreJWS(jws: string, reqId?: string): Promise<AppStoreVerifyResult> {
  if (jws.length === 0 || jws.length > 8000) {
    return { ok: false, status: 401, code: "auth_invalid" };
  }
  if (!hasPinnedAlg(jws)) {
    return { ok: false, status: 401, code: "auth_invalid" };
  }

  const cfg = requireEnv(APPSTORE_ENV_NAMES);
  if (!cfg.ok) {
    logError("appstore_config_missing", { reqId, missingEnv: cfg.missing.join(",") });
    return { ok: false, status: 503, code: "service_unavailable" };
  }
  const appAppleIdRaw = readEnv("APPSTORE_APP_APPLE_ID");
  const environment = cfg.values.APPSTORE_ENVIRONMENT;
  if (environment !== "Sandbox" && environment !== "Production") {
    logError("appstore_config_invalid", {
      reqId,
      reason: "appstore_environment_not_sandbox_or_production",
    });
    return { ok: false, status: 503, code: "service_unavailable" };
  }
  if (environment === "Production" && !appAppleIdRaw) {
    logError("appstore_config_missing", { reqId, missingEnv: "APPSTORE_APP_APPLE_ID" });
    return { ok: false, status: 503, code: "service_unavailable" };
  }

  // APPSTORE_APP_APPLE_ID, when present, must decode to a real numeric App Store id — a garbage
  // value would otherwise be silently coerced to `NaN` by `Number.parseInt` and handed to
  // `SignedDataVerifier`, which is a config error, not something to discover via a confusing
  // downstream verifier failure.
  let appAppleId: number | undefined;
  if (appAppleIdRaw !== undefined) {
    const parsed = Number.parseInt(appAppleIdRaw, 10);
    if (!Number.isSafeInteger(parsed)) {
      logError("appstore_config_invalid", { reqId, reason: "appstore_app_apple_id_not_safe_integer" });
      return { ok: false, status: 503, code: "service_unavailable" };
    }
    appAppleId = parsed;
  }

  const rootCAs = splitPemCertificates(cfg.values.APPSTORE_ROOT_CA_PEM);
  if (rootCAs.length === 0) {
    logError("appstore_config_invalid", {
      reqId,
      reason: "appstore_root_ca_pem_no_parseable_certificates",
    });
    return { ok: false, status: 503, code: "service_unavailable" };
  }

  // Import + verifier construction get their OWN try/catch, deliberately separate from signature
  // verification below. Sharing one catch meant an npm import failure or a `SignedDataVerifier`
  // constructor throw (bad root CA DER, library incompatibility under Deno's Node-compat layer,
  // etc.) was indistinguishable from "this JWS is fraudulent" — that IS a config/runtime problem,
  // not proof the caller is unauthorized, so it must fail as 503, not 401, and it must log.
  // deno-lint-ignore no-explicit-any
  let verifier: any;
  try {
    // Pinned exact version — see supabase/README.md for the audit trail on this dependency.
    const { SignedDataVerifier, Environment } = await import(
      "npm:@apple/app-store-server-library@3.1.0"
    );
    verifier = new SignedDataVerifier(
      rootCAs.map((b) => toNodeBuffer(b)),
      /* enableOnlineChecks */ true,
      environment === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
      cfg.values.APPSTORE_BUNDLE_ID,
      appAppleId,
    );
  } catch (err) {
    // Deliberately narrower than `errorDetails(err)` — never log the full message/stack here, only
    // the error's class/name: this catch wraps root-CA-cert parsing + verifier construction, where
    // an error message could embed a fragment of the malformed cert/config input itself. The class
    // name alone ("the verifier failed to initialize") is enough to point an operator at this
    // function without risking that leak.
    logError("appstore_verifier_init_failed", {
      reqId,
      reason: "verifier_init_threw",
      errorName: err instanceof Error ? err.constructor?.name ?? "Error" : typeof err,
    });
    return { ok: false, status: 503, code: "service_unavailable" };
  }

  try {
    // ASSUMPTION (flagged for reconciliation against the real client): the client attaches a
    // `Transaction.jwsRepresentation` from `Transaction.currentEntitlements` (proof of an active
    // purchase/subscription — carries `originalTransactionId`), NOT an `AppTransaction` JWS (proof
    // of app install/download — no transaction id). If the client instead sends
    // `AppTransaction.jwsRepresentation`, swap this for `verifier.verifyAndDecodeAppTransaction`.
    const decoded = await verifier.verifyAndDecodeTransaction(jws);
    const originalTransactionId: string | undefined = decoded?.originalTransactionId;
    const productId: string | undefined = decoded?.productId;
    const expiresDateMs: number | undefined = decoded?.expiresDate;
    const bundleId: string | undefined = decoded?.bundleId;
    if (
      !originalTransactionId || !productId ||
      typeof expiresDateMs !== "number" || !Number.isFinite(expiresDateMs) ||
      !bundleId
    ) {
      return { ok: false, status: 401, code: "auth_invalid" };
    }
    // Bundle id must match our own configured app — contract §3 `/link`: "Bundle id phải khớp env."
    if (bundleId !== cfg.values.APPSTORE_BUNDLE_ID) {
      return { ok: false, status: 401, code: "auth_invalid" };
    }
    return {
      ok: true,
      transaction: {
        originalTransactionId,
        productId,
        expiresDate: new Date(expiresDateMs).toISOString(),
        bundleId,
      },
    };
  } catch (err) {
    // Signature/chain verification failure, expired transaction, revoked cert, etc. — never leak
    // the library's internal error detail to the CLIENT (opaque per hardening requirement); this
    // IS a real auth failure (fail closed), not a config problem, so 401 not 503. Logging it
    // server-side (unlike the client response) is safe and necessary: this decode/verify failure
    // is about the SUBMITTED JWS, not about our own secrets, and was previously a bare `catch {}`
    // that swallowed the real reason entirely — undiagnosable if a legitimate renewal starts
    // failing verification for a reason that isn't "the transaction is fraudulent".
    logError("appstore_jws_verify_failed", { reqId, reason: "verify_or_decode_threw", ...errorDetails(err) });
    return { ok: false, status: 401, code: "auth_invalid" };
  }
}
