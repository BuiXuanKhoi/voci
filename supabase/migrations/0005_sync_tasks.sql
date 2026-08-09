-- 0005_sync_tasks.sql
--
-- Multi-device sync for task content. Design: `specs/008-sync/design.md` (Opus, 2026-08-09).
--
-- WHY THIS EXISTS NOW: anh Khôi chốt 2026-08-09 rằng app trên Apple Watch phải chạy được khi KHÔNG
-- có iPhone bên cạnh. `WCSession` chỉ sống khi hai máy ở gần nhau, nên watch phải tự nói chuyện với
-- server — điều đó biến sync từ "tính năng paid tier để sau" thành thứ chặn Phase 3 của
-- `specs/007-apple-three-platforms/plan.md`. Trước migration này, server chưa từng lưu MỘT dòng nội
-- dung user nào: toàn bộ schema `public` là entitlements / usage_counters / promo_*.
--
-- ── HAI CHỖ LỆCH CÓ CHỦ Ý SO VỚI CONVENTION CỦA 0002/0003/0004 ────────────────────────────────
--
-- (1) CÓ RLS POLICY THẬT, và client gọi thẳng PostgREST bằng JWT của chính nó — thay vì "bật RLS,
--     không policy nào, mọi thứ qua service-role trong edge function".
--     Lý do: với `entitlements` thì quên một `.eq("user_id", ...)` chỉ lộ tier. Với `sync_tasks`
--     thì quên một `.eq` là lộ TOÀN BỘ TASK CỦA NGƯỜI KHÁC — dữ liệu nhạy cảm nhất sản phẩm có
--     (title, notes, và `sourceTranscript` = lời nói nguyên văn). Ranh giới an ninh không được
--     phép là "lập trình viên nhớ viết where". Ở đây Postgres từ chối ở tầng dưới cùng, dù code
--     phía trên có sai. RPC vì vậy để `security invoker` (mặc định) — nó KHÔNG được bypass RLS.
--
-- (2) CỔNG NẰM TRONG POLICY, không nằm trong client — và nó là **HAI ĐIỀU KIỆN**, không phải một:
--     `public.volar_sync_allowed()` = `volar_is_pro()` **AND** `volar_sync_enabled()`.
--     anh Khôi chốt 2026-08-09: sync là OPT-IN ("nếu pro và user bật sync across device thì sync
--     task lên db"), và công tắc ở mức TÀI KHOẢN chứ không phải từng máy — nên nó sống ở bảng
--     `public.sync_prefs` trên server, không phải `UserDefaults`.
--     Nhờ đặt cả hai vào policy: một user free, HOẶC một máy đang offline chưa kịp biết user vừa
--     tắt sync ở máy khác, đều không ghi được `sync_tasks` kể cả khi gọi thẳng PostgREST bằng curl.
--
-- ── AN TOÀN ─────────────────────────────────────────────────────────────────────────────────────
-- Migration này chỉ TẠO MỚI. Không `drop`, không `alter` bất kỳ đối tượng nào đã tồn tại, không
-- đụng `entitlements`/`usage_counters`/`promo_*` (plan 007 §8: `0002` đã applied, mọi chỉnh sửa
-- phải đi vào migration mới — file này tuân thủ điều đó và cũng không sửa `0003`/`0004`).
-- Safe to re-run: mọi CREATE đều `if not exists` / `create or replace`, mọi policy dùng
-- `drop policy if exists` trước khi tạo lại (Postgres không có `create policy if not exists`).
--
-- ── HAI ĐỒNG HỒ, CỐ Ý TÁCH RỜI (design.md §4) ───────────────────────────────────────────────────
-- `updated_at`        = đồng hồ LOGIC của client. Dùng DUY NHẤT để phân xử ai thắng (LWW).
-- `server_updated_at` = `now()` của Postgres. Dùng DUY NHẤT làm con trỏ "tôi đã thấy tới đâu".
-- Trộn hai cái vào một cột là lỗi kinh điển: một máy lệch đồng hồ sang 2030 vừa thắng mọi xung đột
-- vĩnh viễn, vừa đẩy cursor của mọi máy khác vượt qua dữ liệu thật. Tách ra thì lệch đồng hồ chỉ
-- hỏng phân xử (và `sync_exchange` còn kẹp thêm `least(updated_at, now() + 1 phút)`), không bao
-- giờ làm mất bản ghi.
--
-- ── KHÔNG CÓ ĐƯỜNG NÀO TỰ ĐỘNG XOÁ DỮ LIỆU CỦA USER ─────────────────────────────────────────────
-- anh Khôi chốt 2026-08-09: hết hạn Pro **KHÔNG xoá gì cả**, tắt công tắc cũng **KHÔNG xoá gì cả**.
-- Nguyên văn: *"task tạo ở đâu nằm ở đó thôi — bản gốc luôn ở device tạo ra nó, bản trên cloud chỉ
-- là replica."* Máy B đã kéo về replica của task do máy A tạo thì B **giữ nguyên và sửa được bình
-- thường**, chỉ là không đẩy đi đâu nữa. Không đánh dấu chỉ-đọc, không xoá.
-- Đường xoá thật DUY NHẤT là `public.volar_sync_purge()` — user chủ động bấm, không job nào gọi.
--
-- ── XOÁ LÀ TOMBSTONE, KHÔNG PHẢI XOÁ ────────────────────────────────────────────────────────────
-- `deleted_at` chứ không `delete from`. Xoá cứng thì một máy đang offline không bao giờ biết đã có
-- lệnh xoá — nó chỉ thấy "server không có task này" rồi ĐẨY NGƯỢC LÊN, hồi sinh task đã xoá. Đó là
-- loại lỗi làm user gỡ app.
--
-- ── FK CASCADE LÀ BẮT BUỘC ──────────────────────────────────────────────────────────────────────
-- Cả NĂM bảng đều `references auth.users(id) on delete cascade`. `POST /subscription/delete-account`
-- (Apple Guideline 5.1.1(v)) xoá `auth.users` bằng admin API và dựa HOÀN TOÀN vào cascade. Thiếu
-- cascade ở một bảng user-owned là im lặng phá tính năng xoá tài khoản.

-- -----------------------------------------------------------------------------------------------
-- Helper: "user đang gọi có phải Pro không?"
-- -----------------------------------------------------------------------------------------------
-- `security definer` vì `public.entitlements` bật RLS với ZERO policy — không role nào đọc trực
-- tiếp được. `set search_path = ''` (mọi thứ phải qualified) là bắt buộc với một definer function:
-- không có nó, một schema do kẻ tấn công kiểm soát có thể chèn hàm/toán tử cùng tên.
-- KHÔNG nhận tham số `p_user`: danh tính lấy từ JWT ngay bên trong hàm, nên không có gì để giả mạo.
-- Logic khớp 1:1 với `_shared/auth.ts` (`verifyAccount`): entitlements có NHIỀU dòng mỗi user (một
-- dòng mỗi `source`), tier hiệu lực = "có BẤT KỲ dòng nào tier='pro' và chưa hết hạn". Thời hạn từ
-- các nguồn khác nhau không cộng dồn.
create or replace function public.volar_is_pro()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.entitlements e
    where e.user_id = (select auth.uid())
      and e.tier = 'pro'
      and e.expires_at is not null
      and e.expires_at > now()
  );
$$;

revoke all on function public.volar_is_pro() from public;
revoke all on function public.volar_is_pro() from anon;
-- `authenticated` PHẢI có execute: biểu thức trong RLS policy được đánh giá bằng quyền của role
-- đang truy vấn, không phải quyền của owner. Revoke ở đây là tự khoá mình ra ngoài.
-- An toàn để lộ: hàm chỉ trả về tier CỦA CHÍNH người gọi — `GET /subscription/status` vốn đã nói
-- đúng thông tin đó rồi.
grant execute on function public.volar_is_pro() to authenticated;

-- -----------------------------------------------------------------------------------------------
-- sync_prefs — công tắc sync, MỘT DÒNG MỖI TÀI KHOẢN (không phải mỗi máy)
-- -----------------------------------------------------------------------------------------------
-- anh Khôi chốt 2026-08-09: sync là OPT-IN, và công tắc ở mức TÀI KHOẢN.
--   "nếu pro và user bật sync across device thì sync task lên db"
-- ⇒ điều kiện là **Pro AND toggle bật**, HAI điều kiện. Pro một mình không tự bật sync.
--
-- VÌ SAO CÔNG TẮC PHẢI Ở SERVER, KHÔNG PHẢI `UserDefaults`: "mức tài khoản" mà lưu trên từng máy
-- thì chỉ là lời hứa suông — bốn máy sẽ tin bốn trạng thái khác nhau, và cái máy tin nhầm sẽ đẩy dữ
-- liệu lên trong khi user tưởng đã tắt. Một dòng, một nguồn sự thật, mọi máy đọc cùng chỗ.
--
-- Anh Khôi ĐÃ ĐƯỢC CẢNH BÁO mặt trái và vẫn chọn account-level: **một máy bật là dữ liệu của MỌI
-- máy đang đăng nhập tài khoản đó lên cloud**, và một máy mới đăng nhập sau đó sẽ tự động bắt đầu
-- sync mà không hỏi lại. UI bật lần đầu phải nói thẳng điều này (design.md §8.1).
create table if not exists public.sync_prefs (
  user_id           uuid        not null primary key references auth.users(id) on delete cascade,
  sync_enabled      boolean     not null default false,
  enabled_at        timestamptz,
  enabled_by_device text,
  updated_at        timestamptz not null default now()
);

alter table public.sync_prefs enable row level security;

-- -----------------------------------------------------------------------------------------------
-- sync_devices — máy nào ĐÃ THẬT SỰ sync, để Settings liệt kê ra được
-- -----------------------------------------------------------------------------------------------
-- Chỉ được ghi từ bên trong `sync_exchange`, tức chỉ bởi máy đang thật sự đồng bộ. CỐ Ý KHÔNG phải
-- một bảng đăng ký thiết bị mà mọi máy ping vào lúc khởi động: làm thế là **báo về server sự tồn
-- tại của từng máy TRƯỚC KHI user đồng ý** — đúng cái mà màn xác nhận sinh ra để bảo vệ.
-- Hệ quả đã biết và chấp nhận (design.md §8.1): lần bật ĐẦU TIÊN không liệt kê được máy nào, vì
-- chưa máy nào từng sync. Màn xác nhận nói thẳng LUẬT thay vì bịa ra một danh sách.
create table if not exists public.sync_devices (
  user_id    uuid        not null references auth.users(id) on delete cascade,
  device_id  text        not null,
  label      text,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  primary key (user_id, device_id)
);

alter table public.sync_devices enable row level security;

-- -----------------------------------------------------------------------------------------------
-- Hai helper còn lại
-- -----------------------------------------------------------------------------------------------
-- `security definer` vì `sync_prefs` có RLS, và các policy bên dưới cần đọc nó ngay trong lúc
-- Postgres đang đánh giá policy — một vòng lặp mà `security invoker` không thoát ra được.
-- Không có dòng `sync_prefs` = CHƯA BẬT. Mặc định phải là tắt, không bao giờ là bật.
create or replace function public.volar_sync_enabled()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select coalesce(
    (select p.sync_enabled from public.sync_prefs p where p.user_id = (select auth.uid())),
    false
  );
$$;

revoke all on function public.volar_sync_enabled() from public;
revoke all on function public.volar_sync_enabled() from anon;
grant execute on function public.volar_sync_enabled() to authenticated;

-- HAI điều kiện, gộp làm một để policy đọc được bằng mắt và Postgres chỉ gọi một InitPlan.
-- Đây là hàm mà MỌI policy của `sync_tasks`/`sync_completions`/`sync_rejects` đi qua.
create or replace function public.volar_sync_allowed()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select public.volar_is_pro() and public.volar_sync_enabled();
$$;

revoke all on function public.volar_sync_allowed() from public;
revoke all on function public.volar_sync_allowed() from anon;
grant execute on function public.volar_sync_allowed() to authenticated;

-- Máy khác biết công tắc đã đổi bằng CÁI NÀY. Đọc được KỂ CẢ khi hết Pro hoặc đã tắt sync — nếu nó
-- cũng bị gate thì một máy đã tắt sync sẽ không bao giờ biết vì sao mình bị từ chối, và sẽ hiển thị
-- nhầm thành lỗi mạng. Client gọi lúc khởi động, lúc vào foreground, và sau MỌI 403 từ
-- `sync_exchange`.
create or replace function public.volar_sync_state()
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'isPro',           public.volar_is_pro(),
    'syncEnabled',     public.volar_sync_enabled(),
    'enabledAt',       (select p.enabled_at from public.sync_prefs p where p.user_id = (select auth.uid())),
    'enabledByDevice', (select p.enabled_by_device from public.sync_prefs p where p.user_id = (select auth.uid())),
    'devices',         coalesce(
                         (select jsonb_agg(jsonb_build_object(
                                   'deviceId', d.device_id,
                                   'label',    d.label,
                                   'lastSeen', d.last_seen)
                                 order by d.last_seen desc)
                          from public.sync_devices d where d.user_id = (select auth.uid())),
                         '[]'::jsonb)
  );
$$;

revoke all on function public.volar_sync_state() from public;
revoke all on function public.volar_sync_state() from anon;
grant execute on function public.volar_sync_state() to authenticated;

-- -----------------------------------------------------------------------------------------------
-- sync_tasks — một dòng cho mỗi task của mỗi user
-- -----------------------------------------------------------------------------------------------
-- PK là `(user_id, id)` chứ không phải `id` một mình: `id` do CLIENT sinh (UUID của
-- `VolarTask.id`), nên PK toàn cục sẽ để va chạm giữa hai user trở thành lỗi ghi — và bản thân
-- việc "insert của tôi bị từ chối" đã là một kênh rò rỉ sự tồn tại. Composite PK làm va chạm liên
-- user trở thành bất khả, và mọi index tự nhiên có tiền tố `user_id`.
--
-- `payload` là JSONB nguyên khối, KHÔNG phải 25 cột: server đợt này là ống dẫn ngu, nó không đọc
-- nội dung task. Đổi lại, shape Swift (đã đổi 6 lần trong 3 tuần) đổi được mà không cần migration
-- production. Giá phải trả: chưa search/lọc phía server được — sau này promote vài cột ra là
-- migration CỘNG THÊM, rẻ. `schema_version` để một reader tương lai biết mình đang nhìn shape nào.
create table if not exists public.sync_tasks (
  user_id           uuid        not null references auth.users(id) on delete cascade,
  id                uuid        not null,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  payload           jsonb       not null,
  schema_version    int         not null default 1,
  origin_device     text,
  server_updated_at timestamptz not null default now(),
  primary key (user_id, id),
  -- `octet_length(payload::text)` chứ không `pg_column_size(payload)`: check constraint chỉ nhận
  -- hàm IMMUTABLE, và `pg_column_size` là STABLE (Postgres từ chối lúc tạo constraint).
  constraint sync_tasks_payload_is_object check (jsonb_typeof(payload) = 'object'),
  constraint sync_tasks_payload_size check (octet_length(payload::text) <= 65536)
);

-- Index DUY NHẤT cần cho đường nóng: `where user_id = ? and server_updated_at > ? order by
-- server_updated_at limit N`. Cột đẳng thức trước, cột range sau (leftmost-prefix rule).
create index if not exists sync_tasks_pull_idx
  on public.sync_tasks (user_id, server_updated_at);

alter table public.sync_tasks enable row level security;

-- -----------------------------------------------------------------------------------------------
-- sync_completions — nhật ký hoàn thành, CHỈ-THÊM
-- -----------------------------------------------------------------------------------------------
-- Ánh xạ `CompletionEvent` (`Shared/Model/CompletionLog.swift`), bất biến từ lúc tạo. Vì không bao
-- giờ update/delete, bảng này KHÔNG THỂ có xung đột: `on conflict do nothing` là toàn bộ chính
-- sách merge. Watch vẫn cần chiều ghi lên (bấm xong trên watch phải đẻ ra event).
-- Không có `deleted_at`: một sự kiện lịch sử không bị xoá, kể cả khi task nguồn đã xoá — đúng thiết
-- kế sẵn có ("May dangle after the source task is deleted — by design", `CompletionLog.swift:17`).
create table if not exists public.sync_completions (
  user_id           uuid        not null references auth.users(id) on delete cascade,
  id                uuid        not null,
  task_id           uuid        not null,
  completed_at      timestamptz not null,
  payload           jsonb       not null,
  server_updated_at timestamptz not null default now(),
  primary key (user_id, id),
  constraint sync_completions_payload_is_object check (jsonb_typeof(payload) = 'object'),
  constraint sync_completions_payload_size check (octet_length(payload::text) <= 8192)
);

create index if not exists sync_completions_pull_idx
  on public.sync_completions (user_id, server_updated_at);

alter table public.sync_completions enable row level security;

-- -----------------------------------------------------------------------------------------------
-- sync_rejects — hộp đen của kẻ thua trong một xung đột LWW
-- -----------------------------------------------------------------------------------------------
-- design.md §5: LWW ở mức bản ghi có đúng MỘT kịch bản mất dữ liệu — hai máy cùng offline sửa hai
-- field khác nhau của cùng một task, bản thua bị ghi đè. Với sản phẩm ADHD, "mất việc" phá niềm
-- tin vĩnh viễn, nên bản thua KHÔNG được bốc hơi: nó rơi vào đây nguyên văn.
-- CHỈ ghi khi push thật sự bị từ chối VÌ CŨ (`stored.updated_at > incoming.updated_at`) — đẩy lại
-- một bản ghi y hệt (timestamp bằng nhau) là chuyện thường ngày và KHÔNG sinh dòng nào ở đây. Nhờ
-- vậy bảng này bị chặn tăng trưởng bởi tần suất xung đột thật, không bởi tần suất sync.
-- Chưa có UI đọc nó (design.md §12) — dữ liệu không hoãn, mắt người thì hoãn.
create table if not exists public.sync_rejects (
  user_id       uuid        not null references auth.users(id) on delete cascade,
  id            uuid        not null default gen_random_uuid(),
  task_id       uuid        not null,
  updated_at    timestamptz not null,
  payload       jsonb       not null,
  origin_device text,
  rejected_at   timestamptz not null default now(),
  primary key (user_id, id)
);

create index if not exists sync_rejects_task_idx
  on public.sync_rejects (user_id, task_id, rejected_at);

alter table public.sync_rejects enable row level security;

-- -----------------------------------------------------------------------------------------------
-- Grants + RLS policies
-- -----------------------------------------------------------------------------------------------
-- Grant bảng là ĐIỀU KIỆN CẦN để RLS thực sự ép được gì: `security invoker` + RLS chỉ có nghĩa khi
-- role thật sự có quyền bảng để mà bị policy lọc. `service_role` bỏ qua RLS theo thiết kế của
-- Supabase và không cần grant tường minh.
-- KHÔNG cấp `delete` cho bất kỳ bảng nào: xoá là `deleted_at`, và một hộp đen xoá được thì không
-- còn là hộp đen.
grant select, insert, update on public.sync_tasks       to authenticated;
grant select, insert         on public.sync_completions to authenticated;
grant select, insert         on public.sync_rejects     to authenticated;
grant select, insert, update on public.sync_prefs       to authenticated;
grant select, insert, update on public.sync_devices     to authenticated;

-- `(select auth.uid())` bọc trong subquery là BẮT BUỘC, không phải thẩm mỹ: viết trần `auth.uid()`
-- thì planner gọi lại nó cho TỪNG HÀNG; bọc `select` biến nó thành InitPlan tính đúng một lần
-- (Supabase RLS performance guide — chênh 100x trên bảng lớn).
--
-- ĐIỀU KIỆN LÀ `volar_sync_allowed()` = **Pro AND toggle bật**, không phải Pro một mình.
-- Đặt công tắc vào ĐÂY (chứ không chỉ trong client) là điểm chặt nhất của thiết kế này: một máy
-- đang offline, chưa kịp biết user vừa tắt sync ở máy khác, **vẫn không ghi lên được**. Gate ở
-- client là lời khuyên; gate ở policy là luật.
--
-- Vì sao SELECT cũng bị gate: sync tắt nghĩa là đóng CẢ HAI chiều (design.md §8). An toàn CHỈ VÌ
-- bất biến §2 — mỗi máy luôn giữ replica đầy đủ trên đĩa, nên mất quyền đọc server không bao giờ
-- lấy đi task của ai. Dữ liệu trên server GIỮ NGUYÊN vô thời hạn dù hết Pro hay tắt toggle; chỉ
-- đường ống bị đóng. Muốn xoá thật thì phải gọi `volar_sync_purge()` — user chủ động, không tự động.

drop policy if exists sync_tasks_select on public.sync_tasks;
create policy sync_tasks_select on public.sync_tasks
  for select to authenticated
  using ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

drop policy if exists sync_tasks_insert on public.sync_tasks;
create policy sync_tasks_insert on public.sync_tasks
  for insert to authenticated
  with check ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

-- UPDATE cần CẢ `using` (được phép nhìn thấy hàng để sửa) LẪN `with check` (kết quả sau khi sửa
-- vẫn phải thuộc về mình). Thiếu `with check` là để user đổi `user_id` sang người khác.
drop policy if exists sync_tasks_update on public.sync_tasks;
create policy sync_tasks_update on public.sync_tasks
  for update to authenticated
  using ((select auth.uid()) = user_id and (select public.volar_sync_allowed()))
  with check ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

drop policy if exists sync_completions_select on public.sync_completions;
create policy sync_completions_select on public.sync_completions
  for select to authenticated
  using ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

drop policy if exists sync_completions_insert on public.sync_completions;
create policy sync_completions_insert on public.sync_completions
  for insert to authenticated
  with check ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

drop policy if exists sync_rejects_select on public.sync_rejects;
create policy sync_rejects_select on public.sync_rejects
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists sync_rejects_insert on public.sync_rejects;
create policy sync_rejects_insert on public.sync_rejects
  for insert to authenticated
  with check ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

drop policy if exists sync_devices_select on public.sync_devices;
create policy sync_devices_select on public.sync_devices
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists sync_devices_insert on public.sync_devices;
create policy sync_devices_insert on public.sync_devices
  for insert to authenticated
  with check ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

drop policy if exists sync_devices_update on public.sync_devices;
create policy sync_devices_update on public.sync_devices
  for update to authenticated
  using ((select auth.uid()) = user_id and (select public.volar_sync_allowed()))
  with check ((select auth.uid()) = user_id and (select public.volar_sync_allowed()));

-- `sync_prefs` KHÔNG bị gate bởi `volar_sync_allowed()` — đó sẽ là một vòng lặp tự khoá:
--   · SELECT không gate ⇒ mọi máy luôn đọc được trạng thái công tắc, kể cả khi đã tắt hoặc hết Pro.
--     Gate nó là để một máy bị từ chối mà **không bao giờ biết vì sao**, rồi hiển thị nhầm thành
--     lỗi mạng.
--   · BẬT đòi Pro. TẮT thì LUÔN được, kể cả đã hết Pro — `sync_enabled is false or volar_is_pro()`.
--     Một user hết hạn mà không tắt được công tắc của chính mình là thiết kế thù địch.
drop policy if exists sync_prefs_select on public.sync_prefs;
create policy sync_prefs_select on public.sync_prefs
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists sync_prefs_insert on public.sync_prefs;
create policy sync_prefs_insert on public.sync_prefs
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and (sync_enabled is false or (select public.volar_is_pro()))
  );

drop policy if exists sync_prefs_update on public.sync_prefs;
create policy sync_prefs_update on public.sync_prefs
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and (sync_enabled is false or (select public.volar_is_pro()))
  );

-- -----------------------------------------------------------------------------------------------
-- volar_set_sync_enabled — bật/tắt công tắc
-- -----------------------------------------------------------------------------------------------
-- `security invoker` ⇒ RLS ở trên vẫn ép: bật đòi Pro, tắt thì luôn được. Client không cần biết
-- luật đó, nó chỉ gọi và đọc kết quả trả về.
-- TẮT **KHÔNG XOÁ GÌ** — không xoá trên server, không xoá trên máy nào. Xem `volar_sync_purge()`.
create or replace function public.volar_set_sync_enabled(
  p_enabled boolean,
  p_device  text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user uuid;
begin
  v_user := (select auth.uid());
  if v_user is null then
    raise exception 'sync_not_authenticated' using errcode = '28000';
  end if;

  insert into public.sync_prefs as p (user_id, sync_enabled, enabled_at, enabled_by_device, updated_at)
  values (
    v_user,
    p_enabled,
    case when p_enabled then now() else null end,
    case when p_enabled then p_device else null end,
    now()
  )
  on conflict (user_id) do update
    set sync_enabled      = excluded.sync_enabled,
        -- Giữ nguyên `enabled_at` cũ nếu vốn đã bật rồi (bật lại một công tắc đang bật không phải
        -- một lần bật mới) — màn Settings hiển thị "đã bật từ ..." nên mốc đó phải thật.
        enabled_at        = case
                              when excluded.sync_enabled and p.sync_enabled then p.enabled_at
                              when excluded.sync_enabled then now()
                              else null
                            end,
        enabled_by_device = case
                              when excluded.sync_enabled and p.sync_enabled then p.enabled_by_device
                              when excluded.sync_enabled then excluded.enabled_by_device
                              else null
                            end,
        updated_at        = now();

  return public.volar_sync_state();
end;
$$;

revoke all on function public.volar_set_sync_enabled(boolean, text) from public;
revoke all on function public.volar_set_sync_enabled(boolean, text) from anon;
grant execute on function public.volar_set_sync_enabled(boolean, text) to authenticated;

-- -----------------------------------------------------------------------------------------------
-- volar_sync_purge — xoá dữ liệu đã đồng bộ khỏi server. CHỈ khi user chủ động yêu cầu.
-- -----------------------------------------------------------------------------------------------
-- anh Khôi chốt: tắt công tắc thì **giữ nguyên**, muốn xoá thì user phải tự yêu cầu. Hàm này là
-- đường duy nhất — không có job tự động nào gọi nó, và tắt toggle KHÔNG gọi nó.
-- `security definer` (khác mọi RPC còn lại của file này) là CỐ Ý: không bảng nào cấp `delete` cho
-- `authenticated`, vì "xoá là `deleted_at`" và một hộp đen xoá được thì không còn là hộp đen. Cho
-- user một nút xoá thật mà không cần mở quyền DELETE ra cho PostgREST thì phải đi đường definer.
-- Danh tính lấy từ JWT NGAY TRONG hàm, không nhận tham số user — không có gì để giả mạo.
-- KHÔNG đụng tới máy nào: đây thuần tuý là xoá bản sao trên server. Bản gốc vẫn nằm ở máy tạo ra nó.
create or replace function public.volar_sync_purge()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid;
  v_tasks int;
  v_comps int;
begin
  v_user := (select auth.uid());
  if v_user is null then
    raise exception 'sync_not_authenticated' using errcode = '28000';
  end if;

  delete from public.sync_tasks where user_id = v_user;
  get diagnostics v_tasks = row_count;
  delete from public.sync_completions where user_id = v_user;
  get diagnostics v_comps = row_count;
  delete from public.sync_rejects  where user_id = v_user;
  delete from public.sync_devices  where user_id = v_user;

  return jsonb_build_object('deletedTasks', v_tasks, 'deletedCompletions', v_comps);
end;
$$;

revoke all on function public.volar_sync_purge() from public;
revoke all on function public.volar_sync_purge() from anon;
grant execute on function public.volar_sync_purge() to authenticated;

-- -----------------------------------------------------------------------------------------------
-- sync_exchange — push và pull trong MỘT transaction
-- -----------------------------------------------------------------------------------------------
-- Client gọi `POST /rest/v1/rpc/sync_exchange` với `apikey` + `Authorization: Bearer <access_token>`
-- (cả hai đã có sẵn trong `AccountService.swift`). KHÔNG dựng edge function: sync là lời gọi mạng
-- dày nhất của app, và một tầng chuyển tiếp chỉ thêm cold start + một thứ phải deploy/version.
--
-- `security invoker` (mặc định, ghi rõ ra để không ai "sửa cho giống 0002") — RLS PHẢI áp dụng cho
-- hàm này. Đây là điểm khác biệt duy nhất và quan trọng nhất so với `consume_quota` /
-- `redeem_promo_code`, cả hai đều `security definer` vì chúng phải bỏ qua RLS.
--
-- HAI CURSOR RIÊNG BIỆT, không phải một. Nếu dùng chung một cursor: trang task chạm `limit` ở mốc
-- T1 trong khi completions trả hết tới T2 > T1, cursor chung nhảy lên T2 và NUỐT MẤT mọi task nằm
-- giữa T1 và T2. Tách hai cursor thì không có cách nào sai.
--
-- KHOẢNG CHỒNG LẤN 2 GIÂY: hai transaction lấy `now()` lúc bắt đầu, cái bắt đầu sau vẫn có thể
-- commit trước ⇒ có khe. Luôn quét lùi 2 giây so với cursor. Áp dụng lại một bản ghi đã áp dụng là
-- no-op (LWW idempotent), nên chồng lấn không tốn gì ngoài vài hàng thừa. Rẻ hơn nhiều so với một
-- per-user sequence có row lock. Đây là chủ ý, không phải nợ kỹ thuật.
create or replace function public.sync_exchange(
  p_cursor_tasks       timestamptz default null,
  p_cursor_completions timestamptz default null,
  p_device             text        default null,
  p_device_label       text        default null,
  p_tasks              jsonb       default '[]'::jsonb,
  p_completions        jsonb       default '[]'::jsonb,
  p_limit              int         default 500
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user       uuid;
  v_limit      int;
  v_cur_tasks  timestamptz;
  v_cur_comps  timestamptz;
  v_rejected   uuid[];
  v_tasks_out  jsonb;
  v_comps_out  jsonb;
  v_task_n     int;
  v_comp_n     int;
  v_task_max   timestamptz;
  v_comp_max   timestamptz;
begin
  v_user := (select auth.uid());
  if v_user is null then
    -- 28000 -> PostgREST trả 401. RLS một mình cũng đã chặn, nhưng một lỗi rõ nghĩa tốt hơn "0 hàng".
    raise exception 'sync_not_authenticated' using errcode = '28000';
  end if;

  -- HAI mã lỗi RIÊNG BIỆT, không gộp một. PostgREST đặt nguyên văn `message` vào body JSON, nên
  -- client phân biệt được ba thứ trông giống nhau ở tầng HTTP nhưng phải hiển thị khác hẳn:
  --   `sync_pro_required` -> "Sync là tính năng Pro"     (gợi ý nâng cấp)
  --   `sync_disabled`     -> "Sync đang tắt cho tài khoản này" (gợi ý bật, KHÔNG phải lỗi)
  --   mất mạng            -> im lặng, thử lại sau        (KHÔNG hiện gì cả)
  -- Gộp cả ba thành "sync lỗi" là cách chắc chắn nhất để user tắt công tắc ở máy khác rồi ngồi
  -- debug wifi. Client BẮT BUỘC gọi `volar_sync_state()` sau mỗi 403 để lấy trạng thái thật.
  if not public.volar_is_pro() then
    raise exception 'sync_pro_required' using errcode = '42501';
  end if;
  if not public.volar_sync_enabled() then
    raise exception 'sync_disabled' using errcode = '42501';
  end if;

  v_limit     := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_cur_tasks := coalesce(p_cursor_tasks, '-infinity'::timestamptz);
  v_cur_comps := coalesce(p_cursor_completions, '-infinity'::timestamptz);

  -- ── PUSH: task ────────────────────────────────────────────────────────────────────────────────
  -- `distinct on` là BẮT BUỘC, không phải tối ưu: `on conflict do update` báo lỗi
  -- "cannot affect row a second time" nếu một batch chứa hai dòng cùng id. Giữ dòng mới nhất.
  -- `least(updated_at, now() + 1 phút)` kẹp lệch đồng hồ: một máy sai giờ không thể chiếm quyền
  -- thắng vĩnh viễn. Client đọc lại `updatedAt` server trả về và nhận làm chuẩn.
  -- `where excluded.updated_at > t.updated_at` LÀ chính sách LWW — bản cũ hơn bị bỏ qua im lặng ở
  -- đây rồi được ghi lại vào `sync_rejects` ngay bên dưới.
  -- `deleted_at = excluded.deleted_at` (chứ không `coalesce`) là cố ý: một lần sửa MỚI HƠN sẽ hồi
  -- sinh task đã tombstone. Đó đúng là hướng lệch an toàn — giữ thừa hơn nuốt mất.
  with incoming as (
    select distinct on (e ->> 'id')
           (e ->> 'id')::uuid                                                     as id,
           least((e ->> 'updatedAt')::timestamptz, now() + interval '1 minute')    as updated_at,
           nullif(e ->> 'deletedAt', '')::timestamptz                              as deleted_at,
           coalesce(e -> 'payload', '{}'::jsonb)                                   as payload,
           coalesce((e ->> 'schemaVersion')::int, 1)                               as schema_version
    from jsonb_array_elements(coalesce(p_tasks, '[]'::jsonb)) as e
    where (e ->> 'id') is not null
      and (e ->> 'updatedAt') is not null
    order by e ->> 'id', ((e ->> 'updatedAt')::timestamptz) desc
  ),
  applied as (
    insert into public.sync_tasks as t
      (user_id, id, updated_at, deleted_at, payload, schema_version, origin_device, server_updated_at)
    select v_user, i.id, i.updated_at, i.deleted_at, i.payload, i.schema_version, p_device, now()
    from incoming i
    on conflict (user_id, id) do update
      set updated_at        = excluded.updated_at,
          deleted_at        = excluded.deleted_at,
          payload           = excluded.payload,
          schema_version    = excluded.schema_version,
          origin_device     = excluded.origin_device,
          server_updated_at = now()
      where excluded.updated_at > t.updated_at
    returning t.id
  ),
  rejected as (
    -- Mọi CTE trong một câu lệnh nhìn CÙNG một snapshot, nên `cur` ở đây là giá trị TRƯỚC upsert.
    -- Với dòng không nằm trong `applied` thì trước == sau, nên so sánh này đúng.
    insert into public.sync_rejects as sr (user_id, task_id, updated_at, payload, origin_device)
    select v_user, i.id, i.updated_at, i.payload, p_device
    from incoming i
    join public.sync_tasks cur on cur.user_id = v_user and cur.id = i.id
    where i.id not in (select a.id from applied a)
      and cur.updated_at > i.updated_at
    returning sr.task_id
  )
  select coalesce(array_agg(r.task_id), '{}'::uuid[]) into v_rejected from rejected r;

  -- ── PUSH: completions (chỉ-thêm, không thể xung đột) ──────────────────────────────────────────
  insert into public.sync_completions as c
    (user_id, id, task_id, completed_at, payload, server_updated_at)
  select distinct on (e ->> 'id')
         v_user,
         (e ->> 'id')::uuid,
         (e ->> 'taskId')::uuid,
         (e ->> 'completedAt')::timestamptz,
         coalesce(e -> 'payload', '{}'::jsonb),
         now()
  from jsonb_array_elements(coalesce(p_completions, '[]'::jsonb)) as e
  where (e ->> 'id') is not null
    and (e ->> 'taskId') is not null
    and (e ->> 'completedAt') is not null
  order by e ->> 'id'
  on conflict (user_id, id) do nothing;

  -- ── Ghi nhận máy này đã sync ──────────────────────────────────────────────────────────────────
  -- Chỉ ở ĐÂY, không ở đường nào khác: chỉ máy thật sự đồng bộ mới được ghi tên lên server. Xem
  -- doc của bảng `sync_devices` ở trên về lý do KHÔNG làm registry ping-lúc-khởi-động.
  if p_device is not null then
    insert into public.sync_devices as d (user_id, device_id, label, first_seen, last_seen)
    values (v_user, p_device, p_device_label, now(), now())
    on conflict (user_id, device_id) do update
      set last_seen = now(),
          label     = coalesce(excluded.label, d.label);
  end if;

  -- ── PULL: task ────────────────────────────────────────────────────────────────────────────────
  -- Chạy SAU push trong CÙNG transaction, nên client thấy luôn giá trị server đã chốt cho chính
  -- những dòng nó vừa đẩy (kể cả `updated_at` đã bị kẹp) — không cần một vòng thứ hai để hoà giải.
  with page as (
    select t.id, t.updated_at, t.deleted_at, t.payload, t.schema_version,
           t.server_updated_at, t.origin_device
    from public.sync_tasks t
    where t.user_id = v_user
      and t.server_updated_at > v_cur_tasks - interval '2 seconds'
    order by t.server_updated_at
    limit v_limit
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id',              p.id,
               'updatedAt',       p.updated_at,
               'deletedAt',       p.deleted_at,
               'payload',         p.payload,
               'schemaVersion',   p.schema_version,
               'serverUpdatedAt', p.server_updated_at,
               'originDevice',    p.origin_device
             )
             order by p.server_updated_at
           ),
           '[]'::jsonb
         ),
         count(*)::int,
         max(p.server_updated_at)
    into v_tasks_out, v_task_n, v_task_max
  from page p;

  -- ── PULL: completions ─────────────────────────────────────────────────────────────────────────
  with page as (
    select c.id, c.task_id, c.completed_at, c.payload, c.server_updated_at
    from public.sync_completions c
    where c.user_id = v_user
      and c.server_updated_at > v_cur_comps - interval '2 seconds'
    order by c.server_updated_at
    limit v_limit
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id',              p.id,
               'taskId',          p.task_id,
               'completedAt',     p.completed_at,
               'payload',         p.payload,
               'serverUpdatedAt', p.server_updated_at
             )
             order by p.server_updated_at
           ),
           '[]'::jsonb
         ),
         count(*)::int,
         max(p.server_updated_at)
    into v_comps_out, v_comp_n, v_comp_max
  from page p;

  return jsonb_build_object(
    'cursorTasks',       coalesce(v_task_max, nullif(v_cur_tasks, '-infinity'::timestamptz)),
    'cursorCompletions', coalesce(v_comp_max, nullif(v_cur_comps, '-infinity'::timestamptz)),
    'tasks',             v_tasks_out,
    'completions',       v_comps_out,
    -- `hasMore` = trang này đầy ⇒ gọi lại NGAY với cursor mới, đừng đợi chu kỳ sau.
    'hasMore',           (v_task_n >= v_limit or v_comp_n >= v_limit),
    -- Danh sách task client đẩy lên nhưng THUA vì cũ. Bản thua đã nằm nguyên văn trong
    -- `sync_rejects`; client chỉ cần biết để nhận bản server trả về làm chuẩn.
    'rejected',          to_jsonb(coalesce(v_rejected, '{}'::uuid[]))
  );
end;
$$;

revoke all on function public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int) from public;
revoke all on function public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int) from anon;
grant execute on function public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int) to authenticated;

-- -----------------------------------------------------------------------------------------------
-- NOTE (follow-up, KHÔNG implement ở đây) — cùng convention với 0002/0004
-- -----------------------------------------------------------------------------------------------
-- 1. `sync_tasks` tombstone không bao giờ được dọn. Cần pg_cron:
--       delete from public.sync_tasks
--        where deleted_at is not null and deleted_at < now() - interval '90 days';
--    90 ngày là cố ý dài hơn mọi khoảng offline hợp lý. Hệ quả đã biết và CHẤP NHẬN: một máy offline
--    >90 ngày rồi online lại sẽ HỒI SINH những task nó đã xoá lúc offline — hướng lệch an toàn
--    (giữ thừa hơn nuốt mất), không phải chỗ sót.
-- 2. `sync_rejects` cũng không bao giờ được dọn. Cùng một job, `rejected_at < now() - 90 days`.
-- 3. pg_cron CHƯA từng được bật ở project này (không migration nào tạo extension nào). Ba job dọn
--    dẹp đang treo — `usage_counters` (từ 0002), và hai bảng trên — nên gộp làm một lần bật.
-- 4. Pair-code cho watch (design.md §10: bảng mã một-lần TTL 5 phút + `volar_mint_pair_code()` +
--    `POST /functions/v1/subscription/pair-claim`) CỐ Ý để dành cho `0006_`. Nó thuộc pha watch,
--    không thuộc pha sync, và trộn vào đây sẽ làm migration này khó review hơn mà không sớm hơn
--    được ngày nào.
