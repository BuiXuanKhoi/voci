// Sources/Orchestrator/ClaudeCodeConnector.swift — feature 002 (Phase 6, T041, "Connector agent").
//
// Contract: specs/002-workflow-command-center/contracts/phase6-contract.md section B, behavior
// per specs/002-workflow-command-center/contracts/app-links.md "Claude Code hook" section.
//
// Self-contained: file I/O + JSON only. No dependency on AppState/TaskStore/UI — the App-wiring
// agent (T044, SettingsView.swift) owns the NSOpenPanel prompt, previews `previewHookEntry()`,
// and hands the granted directory URL into `connect(bookmarkedClaudeDir:)` /
// `disconnect(bookmarkedClaudeDir:)`.
//
// URL scheme: `volar` — confirmed live in Resources/Info.plist's CFBundleURLTypes (the
// Voci→Volar rename already landed there; nothing else to change).
//
// UNVERIFIED: written on Windows with no Swift/Xcode toolchain available to compile or run this
// file. Logic, JSON shapes, and API usage were checked by hand against Apple's documented
// behavior (JSONSerialization, security-scoped bookmarks, NSWorkspace) but this has not been
// built or exercised on macOS. Needs a real build + manual connect/disconnect/test-signal pass
// on Mac before shipping.

import Foundation
import AppKit

/// Installs/removes the single Claude Code "Stop" hook that lets an external `claude` CLI run
/// signal Volar (`volar://ai-done?cwd=$PWD`) when it finishes, and offers a manual test-signal.
///
/// Constitution I: this type only ever WRITES that one marker hook into the user's own
/// `~/.claude/settings.json`, always backs the file up first, and never reads or touches
/// anything else under `~/.claude`. All file access goes through a security-scoped URL the user
/// explicitly granted (App Sandbox; see `Resources/Volar.entitlements`), never arbitrary paths.
@MainActor
final class ClaudeCodeConnector {

    /// Snapshot for the Settings UI (T044) to render connect/disconnect state. Not returned
    /// directly by any method below (the contract's `detect()` returns a plain `Bool`); the
    /// caller composes this from `detect()` plus its own "did connect() succeed this session"
    /// bookkeeping, since this type intentionally keeps no app-facing state of its own.
    struct State {
        var installed: Bool
        var claudeDetected: Bool
    }

    /// Human-readable failure for every throwing path here. Never a crash — malformed input,
    /// missing files, and sandbox-access failures all resolve to one of these.
    struct ConnectorError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Constants

    private static let scheme = "volar"
    /// Marker substring used both to *detect* our hook (dedupe on connect) and to *remove only
    /// our hook* on disconnect. Any command containing this substring is considered ours;
    /// everything else — however it's shaped — is left completely untouched.
    private static let markerSubstring = "\(scheme)://"
    private static let hookCommand = "open \"\(scheme)://ai-done?cwd=$PWD\""
    private static let settingsFileName = "settings.json"

    /// UserDefaults key for a durably-persisted bookmark to the granted `~/.claude` directory,
    /// written by `connect(bookmarkedClaudeDir:)` after a successful install. This lets
    /// `detect()` report real state on later launches without re-prompting; it does not replace
    /// the caller (T044/SettingsView) doing its own NSOpenPanel-driven grant/bookmark dance for
    /// the *first* connect — this is purely this type's own follow-up bookkeeping so it stays
    /// self-contained (no AppState dependency).
    private static let claudeDirBookmarkKey = "volar.claudeDirBookmarkData"

    init() {}

    // MARK: - detect()

    /// Best-effort "does `~/.claude` exist" check — ~/.claude/ exists? per contract B.
    ///
    /// **Sandbox reality**: under App Sandbox, a process cannot `stat`/see paths outside its
    /// container or prior grants. Without a previously-granted bookmark, a raw
    /// `FileManager.fileExists(atPath:)` check against `~/.claude` will almost always report
    /// `false` even when the directory genuinely exists — the path is invisible to us, not
    /// absent. So:
    ///   1. If a bookmark was persisted by an earlier successful `connect(bookmarkedClaudeDir:)`,
    ///      resolve it and check the real directory — this is the authoritative case.
    ///   2. Otherwise, fall back to the raw check purely as a best-effort signal (meaningful in
    ///      unsandboxed/dev runs; unreliable — likely a false negative — under a sandboxed
    ///      build). Callers (T044) should treat a `false` here as "unknown / not yet granted,
    ///      offer the picker", not as proof `~/.claude` doesn't exist.
    /// Never throws.
    func detect() -> Bool {
        if let data = UserDefaults.standard.data(forKey: Self.claudeDirBookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() {
                defer { resolved.stopAccessingSecurityScopedResource() }
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
                if exists, isStale {
                    // Re-mint quietly so future detect()/connect() calls keep resolving cleanly
                    // (mirrors SecureImageBookmark's stale-refresh in AmbientBackground.swift).
                    Self.persistBookmark(for: resolved)
                }
                return exists && isDir.boolValue
            }
        }

        // No bookmark yet — best-effort, sandbox-limited fallback (see doc comment above).
        var isDir: ObjCBool = false
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - previewHookEntry()

    /// The exact JSON hook entry that `connect` will append into `hooks.Stop`, for the preview
    /// UI. Matches app-links.md's example byte-for-byte:
    /// `{"type":"command","command":"open \"volar://ai-done?cwd=$PWD\""}`
    func previewHookEntry() -> String {
        "{\"type\":\"command\",\"command\":\"\(Self.jsonEscape(Self.hookCommand))\"}"
    }

    // MARK: - connect()

    /// Installs the hook. Requires a user-granted security-scoped URL to `~/.claude` (from an
    /// NSOpenPanel grant or a bookmark resolved from one — the caller, T044/SettingsView, owns
    /// obtaining it). Sequence, matching the install contract in app-links.md:
    ///
    ///   1. `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`,
    ///      paired via `defer` so a thrown error still releases the scope.
    ///   2. If `settings.json` exists, copy it byte-for-byte to
    ///      `settings.json.volar-backup-<timestamp>` **before any other step that could touch
    ///      it** — the backup always precedes any write, even a failed one.
    ///   3. Parse tolerantly: missing file, empty file, or JSON that fails to parse, or whose
    ///      root isn't an object, all resolve to an empty `{}` root — this can never throw or
    ///      execute anything, it only ever falls back to the safe empty case.
    ///   4. Additive-merge: read `hooks.Stop` as an array (creating `hooks`/`Stop` if absent),
    ///      keep every existing element exactly as-is (whatever shape it is — dict or not), and
    ///      only *append* our entry if no element already contains the `volar://` marker. Every
    ///      other key under `hooks` (e.g. `PreToolUse`) and every other entry in `Stop` is
    ///      passed through untouched — this is what makes the merge additive rather than a
    ///      replace.
    ///   5. Serialize and write atomically (`Data.write(options: .atomic)` — write-to-temp +
    ///      rename, so a crash/interrupt mid-write can't leave a truncated `settings.json`).
    ///   6. Persist a durable bookmark for this connector's own `detect()` bookkeeping.
    ///
    /// Idempotent: calling `connect` again when already connected re-validates/re-writes the
    /// same content rather than appending a second marker entry.
    func connect(bookmarkedClaudeDir: URL) throws {
        guard bookmarkedClaudeDir.startAccessingSecurityScopedResource() else {
            throw ConnectorError(message: "Volar couldn't access the ~/.claude folder you granted. Please reconnect via Settings and try again.")
        }
        defer { bookmarkedClaudeDir.stopAccessingSecurityScopedResource() }

        let settingsURL = bookmarkedClaudeDir.appendingPathComponent(Self.settingsFileName)
        let fm = FileManager.default

        // Backup first, always, before any parse/merge/write — even if what's on disk turns out
        // to be malformed. If there's no existing file there's nothing to protect.
        if fm.fileExists(atPath: settingsURL.path) {
            let backupURL = bookmarkedClaudeDir.appendingPathComponent(
                "\(Self.settingsFileName).volar-backup-\(Self.timestampToken())"
            )
            do {
                try fm.copyItem(at: settingsURL, to: backupURL)
            } catch {
                throw ConnectorError(message: "Volar couldn't back up your existing settings.json, so nothing was changed. (\(error.localizedDescription))")
            }
        }

        let existingData = (try? Data(contentsOf: settingsURL)) ?? Data()
        var root = Self.parseTolerant(existingData)

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var stop = Self.stopArray(from: hooks)

        let alreadyConnected = stop.contains { Self.isMarkerEntry($0) }
        if !alreadyConnected {
            stop.append(Self.hookEntryObject())
        }
        hooks["Stop"] = stop
        root["hooks"] = hooks

        let outData: Data
        do {
            outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw ConnectorError(message: "Volar built a hook entry it couldn't encode as JSON, so nothing was written. (\(error.localizedDescription))")
        }

        do {
            try outData.write(to: settingsURL, options: .atomic)
        } catch {
            throw ConnectorError(message: "Volar couldn't write settings.json (your original is safe in the backup). (\(error.localizedDescription))")
        }

        Self.persistBookmark(for: bookmarkedClaudeDir)
    }

    // MARK: - sendTestSignal()

    /// Opens `volar://ai-done?cwd=<current dir>` via `NSWorkspace` so the user sees the app
    /// register a "received" round-trip after connecting. Never throws — if URL construction
    /// somehow fails, this is a silent no-op (there's nothing destructive it could otherwise do).
    func sendTestSignal() {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "ai-done"
        components.queryItems = [
            URLQueryItem(name: "cwd", value: FileManager.default.currentDirectoryPath)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - disconnect()

    /// Removes ONLY marker-matching entries (command contains `volar://`) from `hooks.Stop`,
    /// leaving every other entry — and every other key under `hooks` — exactly as found.
    ///
    /// Idempotent/safe no-ops: missing `settings.json`, missing/malformed `hooks`, or a `Stop`
    /// array with no marker entries all return without throwing and without touching the file
    /// (no backup is created either, since nothing would be written). A backup is created only
    /// when there is an actual marker entry to remove, immediately before the resulting write.
    func disconnect(bookmarkedClaudeDir: URL) throws {
        guard bookmarkedClaudeDir.startAccessingSecurityScopedResource() else {
            throw ConnectorError(message: "Volar couldn't access the ~/.claude folder you granted. Please reconnect via Settings and try again.")
        }
        defer { bookmarkedClaudeDir.stopAccessingSecurityScopedResource() }

        let settingsURL = bookmarkedClaudeDir.appendingPathComponent(Self.settingsFileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else {
            return // Nothing installed, nothing to disconnect.
        }

        let existingData = (try? Data(contentsOf: settingsURL)) ?? Data()
        var root = Self.parseTolerant(existingData)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return // No `hooks` object at all — nothing of ours to remove.
        }

        let stop = Self.stopArray(from: hooks)
        let filtered = stop.filter { !Self.isMarkerEntry($0) }
        guard filtered.count != stop.count else {
            return // No marker entries present — nothing changed, nothing written.
        }

        let backupURL = bookmarkedClaudeDir.appendingPathComponent(
            "\(Self.settingsFileName).volar-backup-\(Self.timestampToken())"
        )
        do {
            try fm.copyItem(at: settingsURL, to: backupURL)
        } catch {
            throw ConnectorError(message: "Volar couldn't back up your existing settings.json, so nothing was changed. (\(error.localizedDescription))")
        }

        hooks["Stop"] = filtered
        root["hooks"] = hooks

        let outData: Data
        do {
            outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        } catch {
            throw ConnectorError(message: "Volar couldn't encode the updated settings.json, so nothing was written. (\(error.localizedDescription))")
        }

        do {
            try outData.write(to: settingsURL, options: .atomic)
        } catch {
            throw ConnectorError(message: "Volar couldn't write settings.json (your original is safe in the backup). (\(error.localizedDescription))")
        }
    }

    // MARK: - Shared JSON helpers

    /// Parses `data` as a JSON object. Missing file (`data` empty), empty file, JSON that fails
    /// to parse, and JSON whose root isn't an object (e.g. an array or a bare string) all
    /// collapse to `[:]` — this never throws, matching "tolerate missing/empty/malformed by
    /// treating as `{}`".
    private static func parseTolerant(_ data: Data) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return [:] }
        return (obj as? [String: Any]) ?? [:]
    }

    /// `hooks.Stop` as a plain array of whatever elements it actually contains. Elements are
    /// kept as `Any` (not narrowed to `[String: Any]`) so that non-dict/malformed entries survive
    /// an additive-merge round-trip unchanged instead of being silently dropped.
    private static func stopArray(from hooks: [String: Any]) -> [Any] {
        hooks["Stop"] as? [Any] ?? []
    }

    /// True only for entries that are objects with a `command` string containing our scheme
    /// marker. Anything else (not an object, no `command` key, `command` isn't a string, or a
    /// `command` that doesn't mention `volar://`) is never considered "ours".
    private static func isMarkerEntry(_ element: Any) -> Bool {
        guard let dict = element as? [String: Any], let command = dict["command"] as? String else {
            return false
        }
        return command.contains(Self.markerSubstring)
    }

    private static func hookEntryObject() -> [String: Any] {
        ["type": "command", "command": hookCommand]
    }

    private static func timestampToken() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    /// Minimal, correct JSON string-escaping for building `previewHookEntry()`'s literal text by
    /// hand (needed to pin the exact `"type"` then `"command"` key order from app-links.md;
    /// `JSONSerialization` only offers alphabetical-or-unspecified key ordering).
    private static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Bookmark persistence (this connector's own detect() bookkeeping)

    /// Best-effort only, mirroring `SecureImageBookmark.save` (Views/AmbientBackground.swift): a
    /// failure here doesn't undo the `connect()`/`disconnect()` operation that just succeeded,
    /// it only means a later `detect()` falls back to the sandbox-limited raw check and the user
    /// may need to grant access again via Settings.
    private static func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: claudeDirBookmarkKey)
        } catch {
            print("[Volar.ClaudeCodeConnector] persistBookmark failed: \(error)")
        }
    }
}
