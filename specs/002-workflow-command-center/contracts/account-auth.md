# Contract — Account auth, entitlements, quota (2026-07-26)

**Status:** CHỐT bởi anh Khôi 2026-07-26. Supersedes phần "DeviceCheck free-metered" và
"StoreKit JWS làm bearer" trong `parse-proxy.md` và `docs/product-vision-v2.md`.

## 0. Thay đổi kiến trúc

Trước: không account. Free tier auth bằng App Attest (chết trên macOS), paid tier gửi
thẳng StoreKit JWS làm bearer token, rate limit theo `SHA-256(bundleId:originalTransactionId)`.

Giờ: **Supabase Auth là lớp danh tính duy nhất.** Mọi request cloud mang
`Authorization: Bearer <supabase access_token>`. StoreKit JWS KHÔNG còn là bearer — nó chỉ
được nộp MỘT LẦN (và mỗi lần renew) tới `/subscription/link` để nâng account lên `pro`.
Rate limit khoá theo `user_id`.

Hệ quả: App Attest bị **xoá hoàn toàn**; `PARSE_DEV_TOKEN` bypass bị **xoá hoàn toàn**
(không còn cần, vì tạo account free là test được ngay).

## 1. Danh tính & tier

| Tier | Điều kiện | Cloud parse | Groq speech |
|---|---|---|---|
| (chưa login) | — | ❌ fallback on-device | ❌ fallback on-device |
| `free` | có account | 20 / ngày | ❌ |
| `pro` | account + subscription còn hạn | 500 / ngày (fair-use) | 500 / ngày (fair-use) |

- Quota reset theo **ngày UTC** (`current_date` của Postgres). Client hiển thị "còn N lượt".
- Vượt quota → **429**, client **im lặng fallback on-device** (hành vi sẵn có, không đổi).
- Chưa login → client không gọi cloud, dùng on-device. Không hiện lỗi.
- App lõi (capture / task / reminder / focus) **không bao giờ** đòi login.

## 2. Auth endpoints (gọi thẳng Supabase GoTrue, KHÔNG qua edge function)

Base `https://cjaamylayaylbuuhwlnz.supabase.co`, mọi request kèm header
`apikey: sb_publishable_WkBa-2lGcl10NBf8JrCfJA__FPNjjf0`.

| Mục đích | Request |
|---|---|
| Sign in with Apple | `POST /auth/v1/token?grant_type=id_token` — `{"provider":"apple","id_token":"<JWT>","nonce":"<raw nonce>"}` |
| Gửi mã email | `POST /auth/v1/otp` — `{"email":"…","create_user":true}` |
| Xác minh mã email | `POST /auth/v1/verify` — `{"email":"…","token":"123456","type":"email"}` |
| Refresh | `POST /auth/v1/token?grant_type=refresh_token` — `{"refresh_token":"…"}` |
| Đăng xuất | `POST /auth/v1/logout` + `Authorization: Bearer <access_token>` |

Session trả về: `{access_token, refresh_token, expires_at (epoch giây), token_type, user:{id, email}}`.

**Apple nonce:** client sinh nonce ngẫu nhiên, gửi `SHA256(nonce)` cho
`ASAuthorizationAppleIDRequest.nonce`, gửi **nonce thô** cho Supabase. Sai chỗ này → Supabase
từ chối token.

**Apple chỉ trả email lần đăng nhập ĐẦU TIÊN.** Không được phụ thuộc email từ credential ở
lần sau — lấy email từ `session.user.email`.

## 3. Edge function endpoints (bearer = supabase access_token)

### `POST /functions/v1/subscription/link`
Body `{"jws":"<signedTransaction từ StoreKit 2>"}`.
- Verify JWS bằng App Store Server Library (giữ nguyên logic verify + alg pinning sẵn có
  trong `_shared/auth.ts`, chỉ đổi chỗ dùng).
- Lấy `originalTransactionId`, `productId`, `expiresDate`, `bundleId`. Bundle id phải khớp env.
- Upsert `entitlements`. `original_transaction_id` là **UNIQUE**:
  - đã gắn cho chính user này → cập nhật `expires_at` (renew), **200**.
  - đã gắn cho user KHÁC → **409 `subscription_already_linked`** (first-claim-wins, chống
    dùng chung 1 subscription cho nhiều account).
- `200 {"tier":"pro","expiresAt":"…","productId":"…"}`.

### `GET /functions/v1/subscription/status`
`200 {"tier":"free"|"pro","expiresAt":null|"…","parseUsedToday":N,"parseLimit":N,"speechUsedToday":N,"speechLimit":N}`.
`expires_at < now()` → trả `free` (không cần cron hạ tier).

### `POST /functions/v1/subscription/delete-account`
Apple Guideline 5.1.1(v) — **bắt buộc có**, không có là reject.
Xoá `auth.users` bằng service-role admin API (`entitlements`/`usage_counters` cascade theo FK).
`200 {"deleted":true}`. Sau đó client xoá Keychain + về trạng thái signed-out.

### `POST /functions/v1/parse` (đã có)
Đổi auth sang account token. Tier nào cũng gọi được, khác nhau ở quota.

### `POST /functions/v1/groq/audio/transcriptions` (đã có)
**Pro-only.** Free tier → **403 `upgrade_required`**, client fallback on-device.

## 4. Thứ tự gate (BẮT BUỘC, cả 2 route)

```
route → method → content-type → AUTH (verify access_token)
      → tier check → rate/quota (atomic) → đọc & validate body → upstream
```

`parse` hiện đang **validate body TRƯỚC auth** (defect đã ghi backlog 2026-07-26) — sửa luôn
trong đợt này. Ràng buộc cũ "phải đọc rawBody trước auth để bind App Attest clientDataHash"
đã **biến mất** cùng App Attest, nên không còn gì cản việc auth trước.

## 5. Mã lỗi (opaque, không leak chi tiết)

Thân lỗi luôn `{"error":"<code>"}`, thêm `resetAt` khi 429.

`auth_missing` 401 · `auth_invalid` 401 · `upgrade_required` 403 · `quota_exceeded` 429 ·
`rate_limited` 429 · `subscription_already_linked` 409 · `invalid_request` 400 ·
`payload_too_large` 413 · `upstream_error` 502 · `service_unavailable` 503.

Không bao giờ log: access_token, JWS, email, transcript, audio.
Log được: status, user_id **đã hash**, route, đếm, byte, latency.

## 6. Schema (migration `0002_accounts_entitlements.sql`)

```sql
create table public.entitlements (
  user_id                 uuid primary key references auth.users(id) on delete cascade,
  tier                    text not null default 'free' check (tier in ('free','pro')),
  product_id              text,
  original_transaction_id text unique,
  expires_at              timestamptz,
  updated_at              timestamptz not null default now()
);

create table public.usage_counters (
  user_id uuid not null references auth.users(id) on delete cascade,
  route   text not null check (route in ('parse','speech')),
  day     date not null,
  count   int  not null default 0,
  primary key (user_id, route, day)
);
```

- RLS **bật** trên cả 2 bảng, **không tạo policy nào** → chỉ service-role (edge function)
  chạm được. Client không bao giờ query trực tiếp.
- `consume_quota(p_user uuid, p_route text, p_limit int)` phải tăng đếm **atomic trong MỘT
  câu lệnh** (`insert … on conflict do update … where count < limit`), không được read-then-write.
  Trả `(allowed boolean, used int)`.
- Bảng cũ `parse_rate_limit` / `parse_quota` (migration 0001): **drop** — khoá theo hash
  thiết bị không còn ý nghĩa. Chưa có traffic thật nên không cần backfill.
- Khoá quota có cột `route` riêng ⇒ **đóng luôn** backlog "groq và parse dùng chung bucket".

## 7. Env / secrets

Có sẵn tự động trong Edge runtime: `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`SUPABASE_SERVICE_ROLE_KEY`.

Anh Khôi set thủ công: `GEMINI_API_KEY`, `GROQ_API_KEY`, các `APPSTORE_*` (đã dùng sẵn cho
verify JWS).

Tunable (có default trong code, không cần set): `PARSE_LIMIT_FREE=12` (hạ từ 20 ngày
2026-08-09), `PARSE_LIMIT_PRO=500`, `SPEECH_LIMIT_PRO=500`.

**Xoá:** `PARSE_DEV_TOKEN` (`supabase secrets unset PARSE_DEV_TOKEN`).

`config.toml` giữ `verify_jwt = false` — **cố ý**: gateway của Supabase coi cả publishable
key là JWT hợp lệ, mà key đó công khai ⇒ bật verify_jwt KHÔNG phải là xác thực. Function tự
verify token bằng `auth.getUser()` để phân biệt token người dùng thật với anon key.

## 8. StoreKit

Subscription group **"Volar Pro"**, 2 product auto-renewable:

| Product ID | Giá | Ghi chú |
|---|---|---|
| `tech.kioh.Volar.pro.monthly` | $6.99 / tháng | |
| `tech.kioh.Volar.pro.yearly`  | $49.99 / năm | |

- Intro offer **14 ngày free trial** trên cả hai (mỗi Apple ID hưởng 1 lần / group).
- VN storefront: Apple tự map theo bảng tier; anh Khôi kiểm lại số hiển thị ở App Store Connect.
- Renew: client gọi lại `/subscription/link` với JWS mới ở **mỗi lần khởi động app** và sau
  mỗi giao dịch. Không dựng App Store Server Notifications trong đợt này (→ backlog).
- Không có product "free" — free = có account, không mua gì.
