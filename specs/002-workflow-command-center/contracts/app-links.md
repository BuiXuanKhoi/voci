# Contract: `volar://` App Links (inbound signals)

Registered via `CFBundleURLTypes`. Sandbox-compatible; no listening ports. All endpoints are
**inbound, one-way, idempotent, and non-destructive**: a signal may surface work for review
but can never complete, delete, or create tasks.

## `volar://ai-done`

Fired by external agent tooling when an agent run finishes.

| Param | Required | Meaning |
|---|---|---|
| `cwd` | no | Absolute project path of the agent run — used as a matching hint. |
| `tty` | no | Reserved (deferred typing feature). Accepted and stored, unused in v2. |

**Matching algorithm (in order)**: exactly one task waiting-on-AI → mark needs-review;
else `cwd` prefix-match against tasks' `delegation.cwdHint` → unique match wins;
else ambient one-tap disambiguation card listing waiting tasks. Unknown/no waiting tasks →
log locally, ignore silently.

**Effect on match**: external condition satisfied → task becomes eligible ("needs review"
presentation); `DelegationMeta` cleared; menu-bar WIP counter decrements. Duplicate signals
for an already-reviewed task are no-ops.

## `volar://capture`

| Param | Required | Meaning |
|---|---|---|
| `text` | yes | Task text (URL-encoded) — same pipeline as typed capture (parser + confirm card). |
| `source` | no | Origin reference stored in notes. |

Used by the Services/share-extension path (FR-040). Never bypasses the confirm card.

## Claude Code hook (installed by "Connect Claude Code")

Entry appended to `~/.claude/settings.json` → `hooks.Stop` (additive merge; marker = a
`command` string anywhere in the entry containing `volar://`). Stop hooks use Claude Code's
matcher-group shape (no `matcher` key needed for `Stop`):

```json
{
  "hooks": [
    { "type": "command", "command": "open \"volar://ai-done?cwd=$(printf %s \"$PWD\" | base64)\"" }
  ]
}
```

`$PWD` is base64-encoded before being embedded in the `cwd=` query param, so a path containing
a space/`#`/`&`/non-ASCII byte can't break the URL the shell hook constructs. The receiver
(`AppLinkHandler`) base64-decodes `cwd` on receipt, falling back to the raw value for a hook
installed by a previous build.

Install contract: preview exact JSON → backup `settings.json.volar-backup-<timestamp>` →
parse-validate → merge (never replaces existing hooks) → write → test-signal round-trip
confirmation. Uninstall removes only marker-matching entries, recognizing both this
matcher-group shape and the flat `{"type":"command","command":...}` shape written by earlier
builds. File access via user-granted security-scoped bookmark to `~/.claude` (NSOpenPanel
pre-targeted, one grant, persisted).
