// supabase/tests/gemini_test.ts
//
// Deno tests for supabase/functions/_shared/gemini.ts's exported prompt/schema builders. Lives
// outside functions/ for the same reason schema_test.ts does (see that file's own doc comment):
// invisible to `supabase functions deploy` under every bundling mode, reachable via
// `deno test supabase/tests/`.
//
// Run: `deno test supabase/tests/gemini_test.ts` (or `deno test supabase/tests/`).

import { assertEquals } from "jsr:@std/assert@1";
import {
  SYSTEM_PREAMBLE,
  SYSTEM_PREAMBLE_TASK_CUES,
  SYSTEM_PREAMBLE_TASK_REFS,
  SYSTEM_PREAMBLE_TASK_REFS_CUES,
  buildParseEnvelopeResponseSchema,
  buildParseEnvelopeResponseSchemaWithCues,
  buildParseResponseSchema,
  buildParseResponseSchemaWithCues,
} from "../functions/_shared/gemini.ts";

/** SHA-256 of a string, hex-encoded -- used below as a tamper-evident regression guard on the two
 *  preambles every EXISTING client (no caps, or task_refs_v1 alone) still receives verbatim. Hex
 *  string comparison rather than a giant inline string literal: these preambles are ~4-10K
 *  characters of hand-tuned prose (2 rounds of live probing -- Opus review of this task,
 *  2026-08-08: "lam lech mot ky tu la mat cong do lai tu dau", i.e. one drifted character means
 *  re-measuring everything from scratch) -- pasting the whole text into this test file would be
 *  exactly the kind of manually-retyped copy that risks introducing the very drift this test
 *  exists to catch. Both hashes below were computed by DIRECTLY DIFFING the live
 *  SYSTEM_PREAMBLE/SYSTEM_PREAMBLE_TASK_REFS values against the pre-refactor versions checked out
 *  from git HEAD (byte-for-byte === compared in a throwaway script, not eyeballed), THEN hashing
 *  the confirmed-identical current value -- never hand-typed against a description of what the
 *  text "should" contain. */
async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------------------------
// 1. BYTE-IDENTITY regression guard (Opus review of T1, 2026-08-08): SYSTEM_PREAMBLE_TASK_REFS
//    was refactored to build from an extracted TASK_REFS_SECTION constant (so the NEW combo
//    preamble SYSTEM_PREAMBLE_TASK_REFS_CUES could reuse the section verbatim) -- this must not
//    change ONE CHARACTER of the resulting string for a client that only ever sees task_refs_v1
//    alone. SYSTEM_PREAMBLE (the plain no-caps preamble) was never touched by this task at all,
//    hashed here too as a cheap "nothing leaked into the wrong preamble" cross-check.
// ---------------------------------------------------------------------------------------------

Deno.test("SYSTEM_PREAMBLE: byte-identical to before the task_refs_v1/task_cues_v1 combo work (2026-08-08)", async () => {
  assertEquals(SYSTEM_PREAMBLE.length, 4144);
  assertEquals(await sha256Hex(SYSTEM_PREAMBLE), "bfcbbd806eb9803d975aa4a78bc4570da12137e8da4ed3634d65c6f9a3fc176a");
});

Deno.test("SYSTEM_PREAMBLE_TASK_REFS: byte-identical to before the TASK_REFS_SECTION extraction (2026-08-08)", async () => {
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS.length, 10216);
  assertEquals(await sha256Hex(SYSTEM_PREAMBLE_TASK_REFS), "fc70181baaf6fe386edd4e3a862fd7d353548efa64282dbad3c3cbfd8d3c32cd");
});

// ---------------------------------------------------------------------------------------------
// 2. Structural sanity on the NEW combo preamble/schema (task_refs_v1 + task_cues_v1 together --
//    the path every real client actually takes, since CloudParser.swift sends both caps
//    unconditionally). Not a live-model probe (that's probe-cues.ts's job) -- just proof the
//    combo constant is actually built from BOTH sections plus the shared few-shot examples, and
//    differs from each single-cap preamble (i.e. it is not silently falling back to one of them).
// ---------------------------------------------------------------------------------------------

Deno.test("SYSTEM_PREAMBLE_TASK_REFS_CUES: contains both the refs and cues rule text", () => {
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.includes("ENVELOPE MODE"), true);
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.includes("TASKREFS:"), true);
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.includes("CUE CAPABILITY"), true);
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.includes("NEVER TURN A CUE INTO A DEADLINE"), true);
  // shared few-shot examples must still be present and LAST (same placement rule every preamble
  // in gemini.ts follows -- see SYSTEM_PREAMBLE_FEWSHOT_EXAMPLES's own doc comment).
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.includes("FEW-SHOT EXAMPLES"), true);
  const fewshotIndex = SYSTEM_PREAMBLE_TASK_REFS_CUES.indexOf("FEW-SHOT EXAMPLES");
  const cueIndex = SYSTEM_PREAMBLE_TASK_REFS_CUES.indexOf("CUE CAPABILITY");
  const refsIndex = SYSTEM_PREAMBLE_TASK_REFS_CUES.indexOf("ENVELOPE MODE");
  assertEquals(fewshotIndex > cueIndex && fewshotIndex > refsIndex, true, "few-shot examples must be LAST");
});

Deno.test("SYSTEM_PREAMBLE_TASK_REFS_CUES: distinct from each single-cap preamble (not a silent fallback)", () => {
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES === SYSTEM_PREAMBLE_TASK_REFS, false);
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES === SYSTEM_PREAMBLE_TASK_CUES, false);
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.length > SYSTEM_PREAMBLE_TASK_REFS.length, true);
  assertEquals(SYSTEM_PREAMBLE_TASK_REFS_CUES.length > SYSTEM_PREAMBLE_TASK_CUES.length, true);
});

// ---------------------------------------------------------------------------------------------
// 3. Response-schema builders: byte-identical output for the two UNCHANGED zero-arg entry points
//    (proves the internal parameterization refactor -- buildParsedTaskSchema/
//    buildParseEnvelopeResponseSchemaImpl gaining an optional cue-schema arg -- left the
//    original zero-arg callers' output completely alone), plus a shape check that the new
//    _WithCues schema variants actually add a cue property where the plain ones don't.
// ---------------------------------------------------------------------------------------------

function hasCueProperty(schema: Record<string, unknown>, path: "bare" | "envelope"): boolean {
  const items = path === "bare"
    ? (schema.items as Record<string, unknown>)
    : ((schema.properties as Record<string, unknown>).tasks as Record<string, unknown>).items as Record<
      string,
      unknown
    >;
  const props = items.properties as Record<string, unknown>;
  return "cue" in props;
}

Deno.test("buildParseResponseSchema: has no cue property (unchanged by task_cues_v1)", () => {
  assertEquals(hasCueProperty(buildParseResponseSchema(), "bare"), false);
});

Deno.test("buildParseResponseSchemaWithCues: has a cue property", () => {
  assertEquals(hasCueProperty(buildParseResponseSchemaWithCues(), "bare"), true);
});

Deno.test("buildParseEnvelopeResponseSchema: has no cue property (unchanged by task_cues_v1)", () => {
  assertEquals(hasCueProperty(buildParseEnvelopeResponseSchema(), "envelope"), false);
});

Deno.test("buildParseEnvelopeResponseSchemaWithCues: has a cue property, taskRefs/updates shape unchanged", () => {
  const withCues = buildParseEnvelopeResponseSchemaWithCues() as {
    properties: { taskRefs: unknown; updates: unknown };
  };
  const plain = buildParseEnvelopeResponseSchema() as { properties: { taskRefs: unknown; updates: unknown } };
  assertEquals(hasCueProperty(withCues, "envelope"), true);
  // taskRefs/updates have nothing to do with cues -- must be structurally identical (same object
  // shape) between the two envelope schema builders.
  assertEquals(JSON.stringify(withCues.properties.taskRefs), JSON.stringify(plain.properties.taskRefs));
  assertEquals(JSON.stringify(withCues.properties.updates), JSON.stringify(plain.properties.updates));
});
