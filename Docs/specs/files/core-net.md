# Core networking: behaviour specs

Plain-English specs written before the rewrite. Public names stay as listed.

## Networking/JSONRPC.swift
- `RPCError`: error with code, message, optional data; `LocalizedError` shows the message. `methodNotFound` = -32601.
- `ServerRequest`: id (String), method, params; `sessionID` reads `params.session_id`, empty if absent.
- `GatewayEvent`: type, sessionID, payload, optional seq.
- `InboundFrame`: `.response(id,result,error)`, `.event`, `.serverRequest`, `.unknown`. `parse(String)` and `parse(JSONValue)`.
  - method "event": an event from `params` (missing parts become empty/null).
  - method plus string id: a server request (params default to empty object).
  - non-null id and no method: a response; error defaults code -32000 and message "Unknown error".
  - anything else, or bad JSON: unknown.
- `RPCFrames`: `request(id:method:params:)`, `response(id:result:)`, `errorResponse(id:code:message:)`, `encode(JSONValue)` (no slash escaping, `{}` on failure). Tests: HermesRemoteTests.

## Networking/GatewayEventBatch.swift
- `GatewayEventBatch`: thread-safe bag of events. `add` (internal) refuses once taken; `take()` returns all in order and marks taken.
- `GatewayEvent.textPieces` (message.delta, reasoning.delta), `listRefreshes` (sessions/projects/cron changed).
- `droppingRepeatedRefreshes`: keep only the last of each refresh type per session, in place.
- `coalescingText`: merge consecutive same-type same-session text pieces into the first, joining `payload.text`, seq becomes the latest seq. Pieces without a text field are never merged. Tests: LongTurnReturnTests.

## Networking/NetworkWatch.swift
- `NetworkWatch.shared`: lazily started path monitor. `isUsable` (true until the monitor says otherwise), `mark` (count of path changes), `waitForChange(since:upTo:)` returns on change, timeout or cancel.

## Networking/RequestSigner.swift
- `RequestSigner` (authMode, sessionToken, bearer, access, credentialOnEveryRequest). Two inits (from secrets; from parts).
- `headers`: access headers plus session-token header (session mode) or Bearer (password/oauth), only when non-empty.
- `publicHeaders`: all headers if credentialOnEveryRequest, else access headers only.
- `apply(to:includeCredential:)` sets those headers and Accept: application/json.
- `websocketTokenQuery`: `token` item for session mode only. `websocketURL(gateway:token:ticket:)`: ticket wins over token; path /api/ws. Tests: HermesRemoteTests, NollieLinkTests.

## Networking/GatewayConnection.swift
- `AuthMode` (sessionToken/password/oauth; title; usesBearer), `CloudflareAccess` (id/secret, isConfigured, isPartiallyConfigured, header names, headers), `GatewayConnection` (saved gateway metadata, three endpoint-updating helpers, `isManagedLoopbackEndpoint`), `GatewaySecrets` (tokens, bearer, accessTokenExpiresSoon within 60 s).
- Codable keys must not change (stored on devices).

## Networking/GatewayURL.swift
- `GatewayURL.normalize(raw, pathPrefix:, defaultScheme:)`: trims; adds default scheme when none; ws/wss map to http/https; rejects empty, odd schemes, missing host, a query string; drops fragment and credentials; lowercases host; strips pasted route suffixes (/api/ws, /api/status, /api/health, /chat, /login, /api); appends optional prefix once; no trailing slash. Throws `GatewayURLError` with the same texts.
- `isTLS`, `host`, `port`, `pathPrefix`, `description`, `isTailscaleHost` (*.ts.net or 100.64/10), `isPrivateHost` (localhost, .local, dotless, RFC1918, loopback, link-local, fd/fe80/::1).
- `api(path,query:)` builds URL with fully percent-encoded query (unreserved only); `encodedQuery`; `websocket(path,query:)` swaps to ws/wss.

## Networking/HermesAPI.swift
- `HermesAPIError` (transport, htmlResponse, http, unauthorized, decoding, sessionExpired) with texts; `isUnauthorized` true for unauthorized and sessionExpired.
- `EmptyBody`. `HermesAPI` actor: gateway, signer, refresher; `makeSession`, `sessionConfiguration` (ephemeral, no cookies, 30 s / 300 s); `updateSigner`, `updateGateway`, `setRefresher`; `get`, `send` (Encodable body and JSONValue body), `sendMultipart`, `download` (moves into a fresh temp folder named after the `path` query item's last component), `raw` (profile query added unless present, optional timeout, `answers` statuses returned instead of thrown; HTML detection except on a retried call).
- 401 on an authenticated bearer call with a refresher: one shared refresh, then one retry.
- `looksLikeHTML`, `error(for:data:)` (detail from `detail` or `error`; error "session_expired" is sessionExpired; short plain text bodies used; 401 gives unauthorized).

## Networking/NativeAuth.swift
- `NativeAuthError`, `PKCE` (48 random bytes, S256), `Data.base64URLEncodedString`.
- `NativeAuthClient` (main actor): `providers`, `signInWithBrowser` (loopback listener, ASWebAuthenticationSession on scheme hermesremote, state check, exchange), `sessionEnded` (nonisolated handler: cancel maps to cancelled, any other end without callback is noCallback), `checkNativeSignIn` (404 means too old; 403 from nginx means proxy block; everything else ignored), `signInWithPassword`, `exchange`, `refresh` (keeps old refresh token when none returned; unauthorized becomes sessionExpired).
- `LoopbackCallbackServer` (127.0.0.1, any port; first request with a code is delivered once; friendly page back), `LockedFlag.claim()`. Presentation anchor: key window. Tests: SignInTests, DevicePairingTests.

## Networking/ConnectionTester.swift
- `ConnectionTestStep`, `ConnectionTestOutcome`; `ConnectionTester.run` does three legs (status JSON, credentials, websocket ready), stopping at first failure; `probeWebSocket`; `awaitGatewayReady(timeout:receive:cancel:)` reads up to 128 frames, succeeds on gateway.ready, fails on gateway.error or an error response, times out. Tests: ConnectionReadinessTests.

## Networking/GatewaySocket.swift
- `SocketState`, `SocketError`, `GatewaySocket` actor: JSON-RPC over /api/ws; two inits (batch sink / single-event sink); `connect`, `disconnect`, `waitUntilReady(timeout:)`, `call(_:params:timeout:)`, `respond(to:result:)`, `checkAlive(timeout:)`, `state`; static `retryDelay(attempt:)` (1 s for 3 tries, then doubling to 30).
- Reconnect loop with jitter, aborts into authRejected on unauthorized or close 4401; waits for path changes when offline; ping every 15 s; per-call timers that really time out; replies and server requests close the open event batch; unanswered server requests are left open. Tests: SocketTimeoutTests, GatewayIntegrationTests.

## Gateway/GatewayJSON.swift, Gateway/GatewayFrame.swift
- Typed JSON value with accessors, parse/encoded/decode/init(encoding:), Codable and literal conformances; frame classification (answer, refusal, event, question, unreadable), outgoing call/reply/error-reply text. Behaviour unchanged.
