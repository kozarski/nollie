# Nollie reader

A Hermes plugin that lets every bot except the private one read the web politely and for free:

- **A page reader** that plugs in as Hermes's `web_extract` backend (`nollie-reader`). Pages are
  read on this Mac with Nollie's own user agent, `Nollie/0.1 (+https://nollie.app/bot)`.
- **Shared limits for the free search services** Hermes already uses keyless (Exa, Parallel,
  Firecrawl, Keenable), kept in one file-locked place for every bot.
- **`reference_lookup`** and the **reference-sources** skill for free official sources:
  Wikipedia, Wikidata, arXiv, Crossref, PubMed, GitHub, Hacker News and the Internet Archive.

When a site says no, the bot hands the link to a person instead of finding a way around it.

## What the reader does for each page

1. Accepts only public `http` and `https` addresses with no passwords in them. Local names
   (`localhost`, `.local`, `.internal`, cloud metadata names) are refused before any lookup.
2. Resolves the name and refuses it if any answer is private, loopback, link-local (including
   `169.254.169.254`), shared CGNAT space (Tailscale's `100.64.0.0/10`), reserved or multicast.
   IPv4 hidden in IPv6 wrappers is judged as itself. The connection then goes to the address that
   was checked, so a second DNS answer cannot swap in another. Every redirect goes through the
   same checks. Proxies are never used.
3. Reads the site's `robots.txt` (RFC 9309: Nollie's own group, else `*`, longest match, `*` and
   `$` patterns, `Crawl-delay` up to 30 seconds). A missing file allows reading; a site that does
   not answer for `robots.txt` is not read for now. `Content-Signal: ai-input=no` is a no.
   `ai.txt` is honoured when the site has one.
4. Waits its turn: two seconds between requests to the same site, across every bot.
5. Sends one plain request: no cookies, no browser disguise.
6. Treats `X-Robots-Tag` and `<meta name="robots">` / `<meta name="nollie">` as instructions:
   `noai` is a no, `noimageai` leaves image descriptions out, `noarchive` and `nocache` keep the
   page out of the cache.
7. Turns HTML into clean text with Trafilatura, or the careful standard-library reader when the
   reader's own environment is not installed. PDFs are read with pypdf. Plain text, JSON and XML
   pass through.
8. Keeps what it found, refusals included, for an hour in a cache shared by every bot.

### This site wants a person

`401`, `402`, `403`, `407`, `429` and `451` replies, and human-check pages (Cloudflare,
reCAPTCHA, hCaptcha, Turnstile, DataDome, PerimeterX, Imperva and similar), come back as
`This site wants a person: ...` with `blocked_by_policy` set. Hermes never sends a
`blocked_by_policy` result to its keyless rescue, so the page is not tried through Exa,
Parallel, Firecrawl or Keenable. For the next hour `browser_navigate` to that site is blocked
too, with a message asking the bot to share the link. Robots, `ai.txt`, `noai` and private-address
refusals also carry `blocked_by_policy`. A `429` or `503` rests the site for every bot, for its
`Retry-After` or ten minutes.

Never used: stealth browsers, fingerprint changes, CAPTCHA solvers, proxies, archive.today copies of
paywalled pages, or scraped Google and Bing results. The Internet Archive source searches its
collections; it does not fetch Wayback copies of pages.

## Shared limits for search services

Hermes looks up each keyless vendor function by name when its ring runs
(`plugins.web.keyless_mcp.<vendor>_search_keyless`). The plugin wraps those names, so the pinned
backend, the round-robin ring, its failover and the rescue all pass through the same limits.
Calls made with a paid API key are untouched.

| Service | Pace | Soft daily cap |
| :--- | :--- | :--- |
| Exa | 1 a second | 45 (the free tier allows about 50) |
| Parallel | 1 a second | 60 |
| Firecrawl | 1 a second | 30 |
| Keenable | 1 a second | 60 |

Only Exa publishes an anonymous daily figure, so the other caps are deliberately low guesses.
A reply that says to slow down pauses that service for 30 seconds, doubling up to an hour (or for
its `Retry-After`). A reply about a daily quota, or reaching the cap, rests the service until the
next local midnight. A resting service answers with a rate-limit message, which is what makes
Hermes's ring move on to the next service. State lives in `~/.hermes/nollie-reader/services.json`,
locked with `flock`, so every bot's process shares it.

Reference sources share the same mechanism: arXiv waits three seconds between requests, GitHub six,
the rest one second, each with its own daily cap. These are documented APIs for programs, so their
crawler `robots.txt` is not consulted; everything else (agent, public addresses, cache, limits,
"wants a person") applies.

Caps and paces can be changed in `~/.hermes/nollie-reader/settings.json`:

```json
{"services": {"parallel": {"daily": 80}}, "host_interval": 2.0, "cache_ttl": 3600, "handoff_guard": true}
```

## Install

From the repository root:

```sh
python3 Companions/nollie-reader/install.py
python3 Companions/nollie-reader/install.py --apply --with-extractors --enable
```

The first command prints the plan. `--apply` makes a dated, byte-verified backup of each bot's
`config.yaml`, keeps any earlier copy under that bot's `plugin-backups/`, and installs the plugin
for `default`, `career`, `nowhere` and `forager`. The private bot is never touched, and the plugin
does nothing if it is ever loaded there. `--with-extractors` builds the reader's own Python
environment at `~/.hermes/nollie-reader/venv` from the hash-locked `requirements.txt` (wheels only) and
swaps it in only after Trafilatura and pypdf import. Nothing is installed into Hermes's own Python;
extraction runs in a short helper process. `--enable` runs `hermes --profile <bot> plugins enable
nollie-reader`. The installer never edits Hermes config. To route page reading through the reader:

```sh
hermes --profile <bot> config set web.extract_backend nollie-reader
hermes --profile <bot> config set web.keyless_rescue false
```

`web.keyless_rescue: false` stops Hermes sending ordinary failures (a timeout, a 404) to a free
vendor's crawler, so pages are only ever read on this Mac. Search is unaffected: a keyless search
backend is never rescued anyway.

```sh
python3 ~/.hermes/plugins/nollie-reader/control.py status
python3 ~/.hermes/plugins/nollie-reader/control.py clear-cache
```

## Tests

```sh
python3 -m unittest discover -s Companions/nollie-reader/tests -v
```

Every test uses temporary folders and local HTTP servers on `127.0.0.1` with made-up public names;
nothing touches the real network. The Trafilatura and pypdf tests run when `build/reader-venv`
exists (`python3 -m venv build/reader-venv && build/reader-venv/bin/pip install --only-binary :all:
--require-hashes -r Companions/nollie-reader/requirements.txt`). `requirements.in` names what the reader
imports; `requirements.txt` is its locked result, and a managed Mac setup installs the same lock. Tests against Hermes's own code (the real keyless
ring, the real extract rescue path and plugin registration) run when `NOLLIE_HERMES_PYTHON` names the
Python the gateway uses; they import Hermes read-only with bytecode off and a temporary home.

## Libraries

| Library | Licence | Used for |
| :--- | :--- | :--- |
| Trafilatura 2.3.0 | Apache-2.0 | HTML to text |
| pypdf 6.19.0 | BSD-3-Clause | PDF text |
| lxml, lxml_html_clean, jusText, babel, dateparser | BSD | Trafilatura dependencies |
| courlan, htmldate, regex | Apache-2.0 | Trafilatura dependencies |
| charset-normalizer, urllib3, six, pytz, tzlocal | MIT | Trafilatura dependencies |
| python-dateutil | Apache-2.0 or BSD | Trafilatura dependency |
| certifi | MPL-2.0 | Trafilatura dependency |
| tld | MPL-1.1, GPL-2.0 or LGPL-2.1 (used under MPL-1.1) | Trafilatura dependency |

They are installed unmodified into the reader's own environment, with their licence files, and are
not copied into this repository. Everything else is the Python standard library.
