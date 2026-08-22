// supabase/scripts/probe-followup.ts
//
// 🔴 AGENT: KHÔNG TỰ CHẠY FILE NÀY (anh Khôi chốt 2026-08-09 — xem CLAUDE.md ở gốc repo).
// `--dry-run` thì thoải mái. Chi phí: 5 call/lượt chạy (1 seed + 4 case) ≈ 235đ.
//
// 🔴 TỪ 2026-08-21: probe gọi qua edge function `parse` (production), KHÔNG gọi thẳng Gemini nữa.
// `GEMINI_API_KEY` đã bị xoá khỏi `supabase/.env` -- máy local không còn key, key chỉ sống làm
// secret trên Supabase. Vì sao đổi: gọi thẳng Gemini chỉ kiểm được cái prompt, bỏ qua auth
// (`verifyAccount`), quota (`usage_counters`) và validator server (`validateParseEnvelope`) --
// probe xanh mà production vẫn hỏng ở 3 tầng đó thì probe vô nghĩa. Chi phí Gemini KHÔNG đổi: vẫn
// 5 call thật (1 seed + 4 case) ≈ 235đ, và giờ còn ĐỐT QUOTA THẬT của tài khoản test
// `volar-probe@kioh.tech`.
//
// 🔴 CẢNH BÁO: PROBE NÀY HIỆN LÀ SPEC CHƯA XANH ĐƯỢC. Nó mã hoá hành vi HYBRID mà anh Khôi chốt
// 2026-08-21 (câu tự-đứng-được-như-một-việc → tasks + taskRefs GỢI Ý, không updates; câu chỉ-sửa
// thuộc tính → tasks=[] + updates như cũ), còn `SYSTEM_PREAMBLE_TASK_REFS` HÔM NAY vẫn dạy model
// tự trả `updates` cho MỌI câu nhắc tới task cũ. Chạy live ngay bây giờ thì case 1 gần như chắc
// chắn FAIL — đó là hành vi ĐÚNG của probe, không phải lỗi. Chỉ chạy sau khi prompt đã sửa theo
// luật hybrid (xem mục backlog "đổi SYSTEM_PREAMBLE_TASK_REFS sang luật hybrid").
//
// THAY THẾ `probe-task-refs.ts` (14 case, xoá 2026-08-21 theo yêu cầu anh Khôi): probe cũ test
// từng luật prompt riêng lẻ với title bịa sẵn; probe này test đúng MỘT luồng sản phẩm thật — nói
// lượt 1 tạo task, nói lượt 2 dài hơn, model phải tự quyết định GỢI Ý GỘP / TẠO QUAN HỆ / TẠO TASK
// MỚI / CHỈ-SỬA. Title lượt 2 phải khớp lại được với title mà chính model đã đặt ở lượt 1 (chain
// thật, không hardcode). Không deploy (chỉ `functions/` được ship), không chạy trong CI.
//
// Chạy:  deno run --env-file=supabase/.env --allow-net --allow-env supabase/scripts/probe-followup.ts
//        (cần VOLAR_PROBE_EMAIL / VOLAR_PROBE_PASSWORD trong supabase/.env, tài khoản test
//        volar-probe@kioh.tech)
// Dry:   deno run supabase/scripts/probe-followup.ts --dry-run
//        (không cần env, không gọi mạng -- chỉ in payload sẽ gửi; prompt thật nằm ở server, không
//        in được ở đây nữa)

const SUPABASE_URL = "https://cjaamylayaylbuuhwlnz.supabase.co";
const PUBLISHABLE_KEY = "sb_publishable_WkBa-2lGcl10NBf8JrCfJA__FPNjjf0";

// Exactly what `Shared/Parsing/CloudParser.swift:340` sends on EVERY request -- both caps, always.
// This probe used to send `["task_refs_v1"]` alone, which routed the server to the refs-only
// preamble/schema pair: a compatibility shim no shipped client takes. That is the same mistake
// `probe-cues.ts` already paid for once (see `TASK_CUES_SECTION`'s doc comment in gemini.ts: the
// combo shape degraded a rule that passed 3/3 through the refs-only preamble). Probe the shape
// production actually sends, or the probe measures a code path nobody runs.
//
// BASELINE MOVED 2026-08-21: the 3-pass/1-fail numbers recorded in backlog.md were measured on the
// refs-only preamble. They are NOT comparable to runs after this change.
const CLIENT_CAPS = ["task_refs_v1", "task_cues_v1"];

const NOW_VN = "2026-07-28T15:00:00+07:00";
const TZ_VN = "Asia/Ho_Chi_Minh";

interface ConfidenceLike<T> { value: T; confidence: number }
interface TaskLike {
  title?: ConfidenceLike<string>;
  notes?: ConfidenceLike<string>;
  deadline?: ConfidenceLike<string>;
  priority?: ConfidenceLike<number>;
  conditions?: ConfidenceLike<{ kind?: string; refIndex?: number }>[];
}
interface TaskRefLike { titleQuery?: ConfidenceLike<string>; assumeExisting?: boolean }
interface UpdateSetLike {
  deadline?: ConfidenceLike<string>;
  priority?: ConfidenceLike<number>;
  notesAppend?: ConfidenceLike<string>;
}
interface UpdateLike { refIndex?: number; set?: UpdateSetLike }
interface EnvelopeLike { tasks: TaskLike[]; taskRefs: TaskRefLike[]; updates: UpdateLike[] }

function asEnvelope(raw: unknown): EnvelopeLike {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("response is not an object");
  }
  const r = raw as Record<string, unknown>;
  if (!Array.isArray(r.tasks) || !Array.isArray(r.taskRefs) || !Array.isArray(r.updates)) {
    throw new Error(
      `response missing one of tasks/taskRefs/updates as arrays: ${JSON.stringify(raw).slice(0, 300)}`,
    );
  }
  return { tasks: r.tasks, taskRefs: r.taskRefs, updates: r.updates };
}

async function login(): Promise<string> {
  const email = Deno.env.get("VOLAR_PROBE_EMAIL");
  const password = Deno.env.get("VOLAR_PROBE_PASSWORD");
  if (!email || !password) {
    console.error(
      "VOLAR_PROBE_EMAIL / VOLAR_PROBE_PASSWORD is not set.\n" +
        "  Live:    deno run --env-file=supabase/.env --allow-net --allow-env " +
        "supabase/scripts/probe-followup.ts\n" +
        "  Dry run: deno run supabase/scripts/probe-followup.ts --dry-run",
    );
    Deno.exit(2);
  }
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: PUBLISHABLE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (res.status !== 200) {
    const body = (await res.text()).slice(0, 300);
    console.error(`login failed: HTTP ${res.status}: ${body}`);
    Deno.exit(2);
  }
  const json = await res.json();
  return json.access_token as string;
}

async function callParse(token: string, transcript: string, openTaskTitles: string[]): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/parse`, {
    method: "POST",
    headers: {
      apikey: PUBLISHABLE_KEY,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      mode: "parse",
      transcript,
      now: NOW_VN,
      timezone: TZ_VN,
      open_task_titles: openTaskTitles,
      client_caps: CLIENT_CAPS,
    }),
    signal: AbortSignal.timeout(30000),
  });
  if (res.status !== 200) {
    const body = (await res.text()).slice(0, 300);
    if (res.status === 401) {
      throw new Error("HTTP 401: token hỏng/hết hạn — chạy lại probe để login lại");
    }
    if (res.status === 429) {
      throw new Error("HTTP 429: hết quota của tài khoản test");
    }
    throw new Error(`HTTP ${res.status}: ${body}`);
  }
  return await res.json();
}

async function callFollowUp(token: string, transcript: string, openTaskTitles: string[]) {
  const raw = await callParse(token, transcript, openTaskTitles);
  return asEnvelope(raw);
}

interface Case {
  transcript: string;
  why: string;
  check(env: EnvelopeLike, storedTitle: string): string[];
}

const CASES: Case[] = [
  // --- (1) ỨNG VIÊN GỘP (câu tự đứng được như một task). --------------------------------------------
  {
    transcript:
      "Task dems search phải làm xong trong sáng mai, priority cao nhất, cụ thể là sửa query để search được custom metadata",
    why:
      "câu này tự nó mô tả đủ một việc -- AI phải trả task ĐẦY ĐỦ và CHỈ GỢI Ý task cũ, không được " +
      "tự quyết sửa task cũ; quyết định gộp/tạo-mới là của user sau khi local search hiện danh sách " +
      "liên quan",
    check(env, storedTitle) {
      const problems: string[] = [];
      if (env.tasks.length !== 1) {
        problems.push(`tasks: got ${env.tasks.length}, want 1 -- AI tự quyết sửa task cũ thay vì trả task để user chọn`);
        return problems;
      }
      const t = env.tasks[0];
      if (!t.title?.value) {
        problems.push("title: expected non-empty, got absent");
      }
      if (!t.deadline?.value?.startsWith("2026-07-29")) {
        problems.push(`deadline: got "${t.deadline?.value}", want to start with "2026-07-29"`);
      }
      if (t.priority?.value !== 1) {
        problems.push(`priority: got ${t.priority?.value}, want 1`);
      }
      if (!t.notes?.value) {
        problems.push("notes: expected non-empty string, got absent");
      }
      if (env.taskRefs.length !== 1) {
        problems.push(`taskRefs: got ${env.taskRefs.length}, want 1`);
      } else {
        const ref = env.taskRefs[0];
        if (ref.titleQuery?.value !== storedTitle) {
          problems.push(`titleQuery: got "${ref.titleQuery?.value}", want exact "${storedTitle}"`);
        }
        if (ref.assumeExisting !== true) {
          problems.push(`assumeExisting: got ${ref.assumeExisting}, want true`);
        }
      }
      if (env.updates.length !== 0) {
        problems.push(`updates: got ${env.updates.length}, want 0 -- AI tự sửa task cũ; nhánh này phải để user chốt`);
      }
      return problems;
    },
  },

  // --- (2) RELATIONSHIP: task mới phụ thuộc task cũ. ------------------------------------------------
  {
    transcript: "Sau khi xong task dems search thì deploy bản mới lên staging",
    why:
      "câu nói vừa nhắc task cũ vừa tạo việc mới -- phải ra 1 task MỚI + quan hệ trỏ về task cũ, " +
      "không được sửa task cũ",
    check(env, storedTitle) {
      const problems: string[] = [];
      if (env.tasks.length !== 1) {
        problems.push(`tasks: got ${env.tasks.length}, want 1`);
      }
      if (env.taskRefs.length !== 1) {
        problems.push(`taskRefs: got ${env.taskRefs.length}, want 1`);
        return problems;
      }
      const ref = env.taskRefs[0];
      if (ref.titleQuery?.value !== storedTitle) {
        problems.push(`titleQuery: got "${ref.titleQuery?.value}", want exact "${storedTitle}"`);
      }
      if (ref.assumeExisting !== true) {
        problems.push(`assumeExisting: got ${ref.assumeExisting}, want true`);
      }
      const dep = env.tasks
        .flatMap((t) => t.conditions ?? [])
        .find((c) => c.value.kind === "taskDone" && c.value.refIndex === 1);
      if (!dep) {
        problems.push("conditions: no taskDone condition with refIndex=1 (the old task)");
      }
      if (env.updates.length !== 0) {
        problems.push(`updates: got ${env.updates.length}, want 0`);
      }
      return problems;
    },
  },

  // --- (3) TASK MỚI HOÀN TOÀN: chặn bịa liên kết. ---------------------------------------------------
  {
    transcript: "Chiều mai 3 giờ đi khám răng",
    why:
      "không liên quan gì tới task đang mở -- model phải để taskRefs/updates rỗng chứ không móc đại " +
      "vào task duy nhất đang có",
    check(env, storedTitle) {
      const problems: string[] = [];
      if (env.tasks.length !== 1) {
        problems.push(`tasks: got ${env.tasks.length}, want 1`);
      }
      if (env.taskRefs.length !== 0) {
        const fabricated = env.taskRefs.some((r) => r.assumeExisting === true);
        if (fabricated) {
          problems.push(`bịa liên kết tới storedTitle ("${storedTitle}")`);
        } else {
          problems.push(`taskRefs: got ${env.taskRefs.length}, want 0`);
        }
      }
      if (env.updates.length !== 0) {
        problems.push(`updates: got ${env.updates.length}, want 0`);
      }
      return problems;
    },
  },

  // --- (4) CHỈ-SỬA (câu không mô tả việc gì) -- nhánh updates vẫn phải sống. ------------------------
  {
    transcript: "Task dems search dời sang thứ 6",
    why:
      "câu này KHÔNG mô tả việc gì mới, chỉ dời deadline của task đã có; nếu ép thành task mới thì " +
      "đẻ ra title rác. Đây là nửa còn lại của ranh giới hybrid: câu đứng được -> task + gợi ý; câu " +
      "chỉ-sửa -> updates. Nếu model gộp cả hai kiểu vào một nhánh thì hybrid vô nghĩa",
    check(env, storedTitle) {
      const problems: string[] = [];
      if (env.tasks.length !== 0) {
        problems.push(`tasks: got ${env.tasks.length}, want 0 -- đẻ task rác từ câu chỉ-sửa`);
      }
      if (env.taskRefs.length !== 1) {
        problems.push(`taskRefs: got ${env.taskRefs.length}, want 1`);
        return problems;
      }
      const ref = env.taskRefs[0];
      if (ref.titleQuery?.value !== storedTitle) {
        problems.push(`titleQuery: got "${ref.titleQuery?.value}", want exact "${storedTitle}"`);
      }
      if (ref.assumeExisting !== true) {
        problems.push(`assumeExisting: got ${ref.assumeExisting}, want true`);
      }
      const upd = env.updates.find((u) => u.refIndex === 1);
      if (!upd) {
        problems.push("updates: expected 1 entry with refIndex=1, got none");
        return problems;
      }
      if (!upd.set?.deadline?.value?.startsWith("2026-07-31")) {
        problems.push(`set.deadline: got "${upd.set?.deadline?.value}", want to start with "2026-07-31"`);
      }
      const unrequested = (["priority", "notesAppend"] as const).filter((k) => upd.set?.[k] !== undefined);
      if (unrequested.length > 0) {
        problems.push(`set: unrequested field(s) present: ${unrequested.join(", ")}`);
      }
      return problems;
    },
  },
];

/** Prints `indexTerms` for every task in a response. NOT scored pass/fail on purpose: this run
 *  exists to ANSWER a question, not to assert an answer already known. The open question (anh Khoi,
 *  2026-08-21) is whether the model's terms add anything the local index does not already have --
 *  `TaskSearchIndex.terms(of:)` already tokenizes title + notes + sourceTranscript, so a term list
 *  that merely echoes words from the transcript costs output tokens and buys nothing. Read these
 *  lines and judge: terms that are NOT already plain words of the transcript are the only ones that
 *  justify the persistence work downstream (SwiftData migration, sync payload, Windows port).
 *
 *  Two prompt rules to eyeball while reading: no dates/times anywhere in the list, and no invented
 *  synonyms (every term must be words the user actually said). */
function reportIndexTerms(env: EnvelopeLike): void {
  for (const [i, t] of env.tasks.entries()) {
    const terms = (t as { indexTerms?: unknown }).indexTerms;
    const shown = Array.isArray(terms) && terms.length > 0 ? JSON.stringify(terms) : "(none)";
    console.log(`     indexTerms[task ${i + 1}]: ${shown}`);
  }
  console.log("");
}

async function main() {
  const dryRun = Deno.args.includes("--dry-run");

  const seedTranscript = "Trước 10h làm xong task dems search";

  if (dryRun) {
    const placeholderTitle = "Làm xong task dems search";
    console.log(
      "=== DRY RUN -- prompt nằm ở server (edge function `parse`), không in được ở đây nữa. ===\n" +
        "Dry-run chỉ in ENDPOINT + HEADERS + BODY sẽ gửi. Không gọi mạng nên không cần login.\n",
    );
    console.log(`=== ENDPOINT ===\n\nPOST ${SUPABASE_URL}/functions/v1/parse\n`);
    console.log(
      "=== HEADERS ===\n\n" +
        `apikey: ${PUBLISHABLE_KEY}\n` +
        "Authorization: Bearer <access_token>\n" +
        "Content-Type: application/json\n",
    );
    console.log("=== BODY (SEED) ===\n");
    console.log(
      JSON.stringify(
        {
          mode: "parse",
          transcript: seedTranscript,
          now: NOW_VN,
          timezone: TZ_VN,
          open_task_titles: [],
          client_caps: CLIENT_CAPS,
        },
        null,
        2,
      ),
    );
    console.log(
      `\n(storedTitle below is a PLACEHOLDER "${placeholderTitle}" -- live run uses the real title from the seed call.)`,
    );
    for (const [i, c] of CASES.entries()) {
      console.log(`\n=== BODY (case ${i + 1}) ===\n`);
      console.log(
        JSON.stringify(
          {
            mode: "parse",
            transcript: c.transcript,
            now: NOW_VN,
            timezone: TZ_VN,
            open_task_titles: [placeholderTitle],
            client_caps: CLIENT_CAPS,
          },
          null,
          2,
        ),
      );
    }
    return;
  }

  const token = await login();

  let seedEnv: EnvelopeLike;
  try {
    seedEnv = await callFollowUp(token, seedTranscript, []);
  } catch (err) {
    console.error(`SEED threw: ${err instanceof Error ? err.message : String(err)}`);
    Deno.exit(1);
  }
  const storedTitle = seedEnv.tasks[0]?.title?.value;
  if (!storedTitle) {
    console.error(
      `SEED did not produce a task with a title: ${JSON.stringify(seedEnv.tasks).slice(0, 300)}`,
    );
    Deno.exit(1);
  }
  console.log(`SEED storedTitle: "${storedTitle}"`);
  // The seed call is the ONLY one in this run guaranteed to produce a task from a plain,
  // un-referenced sentence, so it is the cleanest read on `indexTerms` quality. Reporting only
  // inside the case loop (as this did on its first pass, 2026-08-21) yields NOTHING at all when a
  // case legitimately returns `tasks: []` -- the expected shape for half the cases here.
  reportIndexTerms(seedEnv);

  let pass = 0;
  let fail = 0;

  for (const [i, c] of CASES.entries()) {
    const label = `[${i + 1}] "${c.transcript}"`;
    try {
      const env = await callFollowUp(token, c.transcript, [storedTitle]);
      const problems = c.check(env, storedTitle);

      if (problems.length === 0) {
        pass++;
        console.log(
          `PASS ${label}  ->  tasks=${env.tasks.length}, taskRefs=${env.taskRefs.length}, updates=${env.updates.length}`,
        );
        reportIndexTerms(env);
      } else {
        fail++;
        console.log(`FAIL ${label}\n${problems.map((p) => `     ${p}`).join("\n")}\n     (${c.why})\n`);
        reportIndexTerms(env);
      }
    } catch (err) {
      fail++;
      console.log(`FAIL ${label}\n     threw: ${err instanceof Error ? err.message : String(err)}\n`);
    }
  }

  console.log(`\n${pass} passed, ${fail} failed, ${CASES.length} total`);
  Deno.exit(fail === 0 ? 0 : 1);
}

await main();
