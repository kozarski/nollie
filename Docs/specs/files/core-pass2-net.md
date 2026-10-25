# NollieCore pass two: networking and small seams

Behaviour is unchanged; only structure and wording moved.

- Native sign-in is three files now. `NativeAuth.swift` holds the client (browser sign-in, password
  sign-in, token trade and renewal). `NativeAuthSupport.swift` holds the error type, the one-off
  secret with its fingerprint, URL-safe base64 and the take-once flag. `LoopbackCallbackServer.swift`
  is the small local web server that catches the browser's return. Access parameters now default to
  an empty Access value, and the provider to none.
- The API client builds each request in one helper, so a retry after renewal rebuilds it the same way.
  Multipart bodies are assembled from a small "part" helper. Error reading is a switch over the
  gateway's explanation.
- The socket keeps its reconnect state in one small value (wanted, ever open, tries). The pause
  before a retry follows a fixed ladder (1, 1, 1, 2, 4, 8, 16, 30 seconds) with the same jitter, and
  a network path change still ends the wait early.
- The connection tester asks for its one-use socket ticket in its own helper.
- Defaults were added to a few parameters (socket reconnect hook, chat title, kanban edit fields,
  turn stats) so existing calls keep compiling.
