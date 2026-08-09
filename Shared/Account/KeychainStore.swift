// Sources/Account/KeychainStore.swift — Keychain-backed persistence for the account session.
//
// Credentials (access/refresh tokens) must NEVER live in `UserDefaults` — this repo's global rule.
// This stores exactly ONE JSON-encoded blob (the whole `AccountSession`) under a single
// `kSecClassGenericPassword` item, keyed by a fixed service+account pair — the "one Keychain item,
// JSON payload" shape asked for, rather than one Keychain item per field.
import Foundation
import Security

/// Not `@MainActor`, not an `actor`: every method below is exactly one synchronous Keychain
/// syscall (`SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete`) with no shared
/// mutable state of this type's own — the Keychain itself is the store — so there is nothing here
/// for Swift 6 concurrency to protect, and no isolation to get wrong. Safe to call synchronously
/// from any context, including a plain SwiftUI view body (mirrors the existing synchronous
/// `UserDefaults.standard.string(forKey:)` reads this codebase already does in `isConfigured`-style
/// checks — a Keychain read is the same cost class).
enum KeychainStore {
    private static let service = "tech.kioh.Volar.account"
    private static let account = "session"

    /// Loads and decodes the persisted session, or `nil` if none is stored, or it's unreadable/
    /// corrupt. Corruption deliberately degrades to "no session" (never throws/crashes) — a
    /// tampered or partially-written blob must behave exactly like "not signed in", not wedge
    /// sign-in forever.
    static func loadSession() -> AccountSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    /// Saves the session as one JSON blob — add-then-update-on-duplicate, since `SecItemAdd`
    /// never overwrites an existing item (it returns `errSecDuplicateItem` instead). This is the
    /// standard Keychain upsert pattern: try add first (the common "first sign-in" case is then
    /// just one syscall), and only fall through to `SecItemUpdate` when an item is already there
    /// (a later refresh/re-verify).
    @discardableResult
    static func saveSession(_ session: AccountSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        // Available as soon as the user has unlocked the Mac once after boot, without requiring
        // the device to be unlocked at THIS exact moment for a background refresh to read it
        // (unlike `.whenUnlocked`, which would fail a refresh attempted while the screen is
        // locked) — appropriate for a background app that may refresh a token while unattended.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }

        let updateQuery = baseQuery()
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        return updateStatus == errSecSuccess
    }

    /// Removes the stored session. `errSecItemNotFound` counts as success — "nothing left" is the
    /// exact postcondition either way, so a sign-out on an already-signed-out session isn't an
    /// error.
    @discardableResult
    static func clearSession() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
