# Behaviour specs: NollieCore chat helpers

Plain-English specs for the files in `Packages/NollieCore/Sources/NollieCore/Chat/` that are being
rewritten. Tests: `Tests/Unit/MarkdownTests*` (tables, lists, images, front matter in
`HermesRemoteTests`), `ChatMediaTests`, `BotsHomeTests`, `PlainReplyTests`, `ProjectsAndGoalsTests`
(AwayGrace), `AutomatedReplyTests` (TranscriptCache.url).

## MarkdownBlocks.swift
Splits a reply into display blocks, cheaply enough to run at every streaming redraw.

Public API (must not change): `MarkdownListItem(depth:marker:text:)` with `Marker` = bullet,
number(Int), task(checked:); `MarkdownColumnAlignment` leading/center/trailing; `MarkdownTable`
(header, alignments, rows, `cell(row:column:)`, `alignment(of:)`, `spokenCell(row:column:)`,
static `plain(_:)`, `markdown`); `MarkdownBlock` enum (paragraph, heading(level:text:),
code(language:text:closed:), list, quote, table, image(alt:url:link:), rule) with `id` = hash;
`MarkdownParser.blocks(from:)`, `MarkdownParser.inline(_:)`.

Behaviour:
- CRLF is read as LF. A closed leading YAML front matter block (first line `---`, second line a
  `key:` pair, closed by `---` or `...`) is dropped; a BOM is ignored; anything else starting with
  `---` is untouched.
- Fenced code with ``` or ~~~ (language after the fence, optional). Closing line must start with
  the same fence marker. An unterminated fence still yields a code block with `closed: false`.
  Code lines are appended in place (linear time).
- Blank line ends paragraph/list/quote. `---`, `***`, `___` alone is a rule. `#`..`######` plus a
  space is a heading (7 hashes or no space is text).
- A line that is only an image (`![alt](src "title")`, or `[![alt](src)](href)`) is an image block;
  the link wrapper must be complete or absent.
- Table: a header line containing a pipe followed by a delimiter row (only `| - : space tab`, at
  least one dash and one pipe, each cell dashes with optional colons) with the same cell count.
  Alignment from colons. Body rows continue while lines are non-empty and hold a pipe; rows are
  padded or cut to the header width. A lone header line stays a paragraph. Cells split on pipes
  except `\|` (becomes a literal pipe) and pipes inside backtick code spans; other backslashes
  are kept; leading and trailing outer pipes are dropped; cells are trimmed.
- Lists: `- `, `* `, `+ ` bullets; `1. ` or `1) ` numbers (up to 9 digits). Depth comes from
  indentation seen so far (tab = 4), capped at 6. Ordered numbers count up from the first number
  at each depth; deeper counters reset. A bullet starting `[ ]` / `[x]` (any case) is a task, its
  box removed. A different list kind at the top level starts a new list. An indented (2+) line
  after an item continues the item's text. A bullet or number line ends a pending paragraph.
  A quote line (`>`) ends a list.
- Quote lines (`> `) gather into one quote block, joined by newlines, marker stripped.
- Everything else is paragraph lines joined by newline (untrimmed original lines).
- `inline` turns inline markdown into AttributedString (inline-only, whitespace preserved,
  partial parse allowed), falling back to plain text.
- `MarkdownTable.plain` reduces inline markdown to words, trimmed, cached (NSCache, 2000).
  `spokenCell` is "Header: value", or whichever is non-empty. `markdown` writes the table back as
  GitHub markdown with `|` escaped and delimiters `---`, `:---:`, `---:`. Only computed
  properties may be added to MarkdownTable (identity is hashed).

## ChatMedia.swift
Finding pictures, videos and files a reply or tool output refers to, and fetching and keeping them.

- `MediaRef` (candidates, name, id = first candidate or name; `init(candidates:name:)`,
  `init(path:)`; name defaults to last path component or "image"). `imageExtensions` (png jpg jpeg
  gif webp heic heif bmp), `videoExtensions` (mp4 mov m4v), `isImage`, `isVideo` by extension, any case.
- `MediaScan.images(in:)`: `MEDIA:/path` tokens, markdown images whose target is a path, and bare
  path lines (start `/` or `~/`, no spaces); only image extensions, path must start `/` or `~`;
  trailing punctuation and wrapping quotes/brackets cleaned; no duplicates; order: MEDIA, markdown,
  bare lines. CRLF handled.
- `imagePaths(inToolOutput:)` / `videoPaths(inToolOutput:)`: absolute or `~` paths with those
  extensions anywhere, preceded by start, whitespace, quote, backtick, `(`, `=` or `:`; no spaces;
  case-insensitive; deduped; video must not run on into more name characters.
- `textWithoutMedia`: removes MEDIA tokens, replaces markdown images with a gateway path by their
  alt, leaves web images, replaces links to gateway files (plain or `<...>` targets, not images)
  by their words, drops lines that are only a path to an image or file, collapses 3+ newlines to 2,
  trims.
- `attachedImageNames(in:)` reads `[User attached image: name]` marks; `userTextWithoutAttachments`
  removes them and trims. `attachedImageRef(name:profile:)` gives candidates
  `~/.hermes/profiles/<p>/images/<name>` (non-default profile only), `~/.hermes/images/<name>`,
  `~/.hermes/profiles/default/images/<name>`.
- `files(in:)`: non-image files from MEDIA tokens, markdown links (angle-bracket targets may hold
  spaces; plain targets percent-decoded), and bare path lines; only `isFilePath`; deduped; name
  from path.
- `isFilePath`: starts `/` or `~/`, not ending `/`, no `://`, name has an extension of 1-6
  letters/digits and a non-empty stem.
- `FileKind.of(name)` mapping: pdf; table (csv tsv xls xlsx numbers); archive (zip gz tgz tar 7z
  bz2 xz dmg); audio (mp3 m4a wav aac flac ogg opus aiff); video (mp4 mov m4v webm mkv avi);
  text (txt md markdown log rtf json yaml yml toml xml html htm); code (swift py js ts rb go rs c
  h cpp java kt sh sql css); other.
- `GatewayMediaAPI(api:profile:)`: `fetch(_ ref:) -> (Data, String)` tries each candidate in
  order, keeps the last error ("No path to try." transport error when empty); `fetch(path:)` asks
  `GET /api/media?path=`, then falls back to `/api/files/read?path=` when the first failed with
  403, 404, 415 (or a non-HTTP error is not rethrown: only other HTTP statuses are thrown) or
  returned no data. Replies carry `data_url` or `dataUrl` (`data:...;base64,...`).
  "The gateway sent no image data." when the fallback decodes to nothing.
- `MediaStore` actor: `shared`, `init()` uses `NolliePaths.current.media`, `key(gateway:path:)`
  = 32 hex characters (first 16 bytes of SHA-256 of "gateway|path"); `localURL(for:gateway:api:)`
  returns an existing cached candidate file, else fetches once (concurrent callers share one
  task) and writes atomically; `localFile(for:gateway:download:)` same but moves a downloaded
  temp file into place, trying each candidate; `cached(_:gateway:)`. Files are named key plus
  lowercase extension.

## PlainReply.swift
A reply as plain words for previews and notifications.
- `PlainReply.text` runs the whole reply through the incremental filter and joins the pieces with
  spaces, collapsing double spaces, trimmed. Constants `codeOmitted`, `tableOmitted`,
  `cardOmitted` keep their sentences.
- `PlainReply.Incremental` (internal, tests use `init()`, `feed(_:) -> [String]`, `finish()`):
  holds the unfinished line; whole lines are released as they complete; a long unfinished
  paragraph (no pipe, not in a fence) releases whole sentences early at the last `.!?…` followed
  by a space, only if outside backticks, brackets, parens and balanced `*`, and at least 12
  characters in. Lines first go through `MediaScan.textWithoutMedia`.
- Front matter on the first line is skipped (`---`, then `key:` line, to `---`/`...`); a `---`
  first line not followed by a key is a rule (no words).
- Fences: contents give nothing; on close one note (html/htm language gives the card note, else
  code note); an unclosed fence gets its note on `finish`.
- Tables: rows with outer pipes count at once; a header line with a pipe but no outer pipes is
  held until the next line: a delimiter row confirms the table; otherwise its words are released
  (and the next line handled normally). A run of table rows gives one table note when the run
  ends (blank line, other text, fence or finish). A held header at `finish` is said as words.
- Rules (`---`, `***`, `___`) and blank lines give nothing.
- `inlineWords`: strips heading hashes, bullet or number markers, quote marker; task boxes read
  "Done: " or "To do: "; images read their alt or "an image"; links read their text; code spans,
  bold, underline-bold, single emphasis (with word boundary care), strikethrough lose their marks;
  `&nbsp;` is a space; heading, bullet and task lines get a full stop if they have no end mark.

## InterruptedTurn.swift
- `InterruptedTurn.parse(text)`: trimmed text at most 240 chars, one line, starts (any case) with
  "operation interrupted". Bare or with a lone period: `InterruptedTurn()`. Otherwise needs a
  colon or "during " next; colon form drops the colon; trailing periods dropped; empty gives nil
  `doing`. Anything else is nil. `Cause` enum cases: `appWasAway`, `stopped`.
- `AwayGrace`: `envKey` (the unused `configPath` was dropped), `gatewayDefault` 20, `seconds`, `envOverride`, `effective`,
  `isShort` (effective > 0 and < 600), `choices` [20, 600, 3600, 28800, 0], `label(_:)` ("Never
  stop it", "N seconds", "N minutes", "1 hour", "N hours"), `read(config:)` (value under optional
  `config` key, then `dashboard.ws_orphan_reap_grace_s`, number or numeric string, floor at 0),
  `writeBody(seconds:)` nested config object.

## TranscriptCache.swift
Last transcript per session, kept as JSON under the transcripts dir of `NolliePaths.current`, in
a folder per connection UUID. `url(connection:storedID:)` nil for an empty id, "/" in ids becomes
"_", folder created. `load` decodes `[TranscriptMessage]` or nil. `save` keeps the last 200 items,
maps each to a message (user, assistant (skip empty text), tool, system, steer as user, error;
subagent rows skipped), then encodes and writes atomically on a serial utility queue. `flush()`
waits for queued writes. `clearAll()` waits then removes the whole transcripts folder.

## ApprovalRisk.swift
`ApprovalRisk.isRisky(ApprovalRequest) -> Bool`. In order: smart-denied true; pattern key with the
Ask first prefix true; known file-changing or code-running tool names true; read-only tool names
with no command false; words in the description (delete, write, install, pay, send ...) true;
words in the pattern key true; a non-empty command is judged by regex patterns (sudo, rm, mv/cp,
redirection, in-place edit, chmod, kill, service control, git writes, package installs, container
and cloud mutations, POST/PUT curl or pipe to shell, mail, payments, database writes, secrets
paths); otherwise false.

## DeviceTranscriber.swift
`DeviceTranscriber.transcribe(file:locale:) async throws -> String` with SpeechAnalyzer and
SpeechTranscriber: pick the supported locale (else throw `Failure`, a struct holding the locale),
install assets if needed, analyze the file, finalize, join result pieces with spaces, tidy. Only
`transcribe` is used by callers, so `supportedLocale(for:)` and the unused `assetsMissing` case
were dropped.

## AutomatedReply.swift
Already under the bar (4% shared); left as is.
