# Core security files: behaviour specs

Written before the files were replaced. Plain English only.

## Security/Keychain.swift
A namespace for the app's generic-password Keychain items.
- `service`: the base bundle id plus ".gateways". `baseBundleID`: the running bundle id, with any extension
  or companion suffix (notificationcontent, notificationservice, notifications, background-alerts) cut off,
  so every process reads the same items. Falls back to `AppIdentity.bundleID`.
- `accessGroup` (settable, nil by default) puts items in a shared group. `sharedGroupFromBundle()` builds
  "<AppIdentifierPrefix><base id>.shared" from Info.plist, nil when the prefix is missing or empty.
- `memoryOnly` (debug builds only): the demo copy keeps items in a locked in-process dictionary.
- `set(_:account:)` updates the item or adds it (accessible after first unlock, this device only); throws
  `KeychainError`. `get(account:)` returns the data or nil. `delete(account:)` ignores the result.
  `setCodable` / `getCodable` wrap JSON.
- `deleteAll(service:)` removes every item of a service in every reachable group; true when none is left
  (success or not found).
- `migrateToAccessGroupIfNeeded()`: with a group set, copies items from the old default group into it; keeps
  existing destination values; no-op in memory mode or without a group.
- On macOS every query asks for the data-protection keychain.
- `KeychainError(status:)`, a `LocalizedError` saying "Keychain error <n>".
Tests: AppIdentityTests, indirectly most Keychain-backed tests (memory mode).

## Security/RememberedSignIn.swift
- `RememberedSignIn` (Codable, Equatable, Sendable): provider, username, password, optional gateway address.
  Public init takes all four. `belongs(to:)` is true only for the same gateway; one with no address belongs
  nowhere. Printing, debug printing and mirroring never show username or password.
- `RememberedSignInBackend` (class protocol): `write`, `read(account:context:)` (nil when absent),
  `delete(account:)` returning false when it may still exist, `accounts()` returning nil when unreadable.
- `KeychainRememberedSignInBackend`: own service (base id + ".remembered"), protection "when passcode set,
  this device only", access flags user presence, never synchronizable, data-protection keychain on Mac,
  access group when set. Static `query(account:)`, `accessControl()`, `addAttributes(_:account:)`, `deleted(status:)`,
  `accounts(status:found:)`. Write deletes then adds. Listing uses a context that may not prompt. Locked
  device while listing is "unknown" (nil), not "none".
- `MemoryRememberedSignInBackend`: dictionary; `items`, `readsWithContext`, `unreadable`, `undeletable`.
- `RememberedSignInVault` (main actor, observable): `ids`, `isKnown`, `pendingForgets`, `reload()`,
  `contains`, `remember`, `signIn(for:context:)`, `forget` (true when deleted), `standard()` (memory in
  demo). Accounts are "signin.<uuid>". Pending forgets persist as sorted uuid strings in UserDefaults under
  `pendingForgetsKey`, removed when empty. Reload retries pending deletes, then reads the account list;
  a failed list keeps what was known; pending ids are never counted. Reading a missing item drops the id.
  A pending id returns nil from `signIn` without touching the backend. Remembering clears a pending mark.
Tests: RememberedSignInTests, AppIdentityTests.

## Security/ConnectionStore.swift
Main-actor observable list of saved gateways. Metadata index in Keychain account "connections.index",
secrets per gateway in "secrets.<uuid>", active id in UserDefaults "activeConnectionID".
- `connections`, `activeConnectionID` (writes through to defaults), `active`, `connection(id:)`,
  lazy `remembered` vault.
- Init loads the index; active id is the saved one when it still exists, else the first.
- `upsert(_:secrets:)` sets hasAccessHeaders from the secrets, writes secrets first, then the index, then the
  list; first connection becomes active. Throws on Keychain failure leaving memory untouched.
- `updateMetadata`, `secrets(for:)` (empty when none), `saveSecrets` (also refreshes hasAccessHeaders),
  `delete(id:)` (removes secrets, remembered sign-in, linked Mac trust pin; moves active on).

## Security/BotLooks.swift
Codable bundle of per-profile colours, avatar choices and small photo thumbnails, mirrored into the shared
Keychain account "botLooks" for the notification extensions. `load()`, `save()`.
`key(profile:label:)` finds the stored key by profile, then label, then case-insensitively; nil if unknown.
`choice(key:profile:)` resolves a `CharacterChoice`; a photo choice with no photo falls back to its look.
Tests: BotIdentityTests (round trip).

## SignIns/SavedSignIns.swift
Mac-only saved website sign-ins. Types: `SavedSignIn` (id, site, username, createdAt), `SignInSecret`
(password, trimmed optional note, `hasNote`, never printed), `SignInSite` (`normalize`, `matches`, `best`),
`SavedSignInBackend` protocol (`add`, `read`, `delete`, `list`), `KeychainSavedSignInBackend` (two items per
sign-in: secret under ".signins" with user-presence access control, listing under ".signins.list" readable
while unlocked; statics `service`, `listService`, `protection`, `accessFlags`, `query`, `accessControl`,
`secretAttributes`, `listingAttributes`, `quiet`), `MemorySavedSignInBackend` (`items`, `reads`,
`readsWithContext`; duplicate add throws), `SavedSignInError` (copy unchanged), `SavedSignInStore`.
- `normalize`: trims, strips scheme, path, query, fragment, port, trailing dots; refuses user info, spaces,
  IP addresses, single labels, bad labels, over-long names; lowercases; punycode for non-ASCII.
- `matches`: equal or a subdomain. `best`: most specific, ties go to the older item.
- Store: items sorted by site then username; `reload` only publishes real changes; `save` validates (bad
  site, empty username, empty password, duplicate site), replaces by deleting first on an edit, adds,
  reloads, calls `onChange` with sites; `remove`; `reveal` (asks, then reads); `secret(_:context:)`
  (unreadable on read or decode failure, gone plus reload when missing); `confirmOwner`.
Tests: SavedSignInTests, SignInSnapshotTests.

## Characters/CharacterMotion.swift, Gateway/Generated/GatewayWireTypes1.swift and 5
Mostly new already. Only the few matching runs get reshaped; behaviour unchanged.
