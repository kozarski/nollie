---
name: reference-sources
description: "Free official reference sources (Wikipedia, Wikidata, arXiv, Crossref, PubMed, GitHub, Hacker News, Internet Archive) and polite web research."
version: 0.1.0
author: Nollie
platforms: [macos]
metadata:
  hermes:
    tags: [Research, Reference, Wikipedia, Papers, Citations]
---

# Reference sources

Use `reference_lookup` before a general web search when one of these sources fits. Each is a free,
official API, so answers are fast and the source can be cited.

| Need | Source | Search with | Open one with |
| :--- | :--- | :--- | :--- |
| Background on a topic, person or place | `wikipedia` | `query` | `id`: the page title |
| Structured facts (dates, identifiers, places) | `wikidata` | `query` | `id`: a Q-id such as Q42 |
| Preprints in physics, maths, CS and more | `arxiv` | `query` (or `au:`, `ti:`, `cat:`) | `id`: an arXiv id |
| A paper's DOI, venue and authors | `crossref` | `query` | `id`: a DOI |
| Medical and life-science papers | `pubmed` | `query` | `id`: a PubMed id |
| Open-source projects | `github` | `query` | `id`: owner/repo |
| Tech discussion and launches | `hackernews` | `query` | `id`: an item id |
| Old books, films, audio and software | `archive` | `query` | `id`: an archive.org identifier |

Give `language` for Wikipedia and Wikidata when the person writes in another language.

## Being polite

Every bot on this Mac shares the same limits: about one request a second per source (one every
three seconds for arXiv, one every six for GitHub), a daily allowance, and a rest when a source asks
to slow down. Searches are cached for an hour, so asking the same thing twice costs nothing.

- If a source is resting, use another source or tell the person, then carry on with what you have.
- Search the source once with a good query rather than many near-identical ones.
- Read full pages and PDFs with `web_extract`; Nollie's reader fetches them on this Mac.

## When a site says no

When a result says "This site wants a person", the site asked for a sign-in, turned automated
readers away, asked them to slow down or showed a human check. Stop there. Share the link and ask the
person to open it. Do not try the browser, another search service, a cached copy or an archive copy
instead. The same goes for robots.txt refusals and pages that ask AI tools not to use them.

Never scrape Google or Bing result pages, never use archive.today copies of paywalled pages, and
never use stealth browsers, proxies or CAPTCHA solvers.
