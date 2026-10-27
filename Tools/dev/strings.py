#!/usr/bin/env python3
"""Keeps Nollie's String Catalogs in step with the code, and reports on them.

  strings.py sync <derived data> [<derived data> ...]
      Brings every catalog up to date with the strings a build found (build with SWIFT_EMIT_LOC_STRINGS=YES so
      the NollieCore package reports its strings too). Pass the iPhone build's and the Mac build's derived data,
      so strings only one of them uses are not marked stale. Xcode keeps Localizable catalogs in step by itself
      when it builds; NollieCore is a package, so its table (Shared/Core.xcstrings) is only kept here.
  strings.py check
      How many strings each language has, how many still need review, and any placeholder or em-dash problems.

Docs/languages.md explains the catalogs and how a language is switched on.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ["de", "fr", "es", "ja"]

# Each catalog, and the targets whose strings it holds (the folder names Xcode gives their intermediates).
CATALOGS = {
    "Apps/Nollie/Resources/Localizable.xcstrings": ["Nollie", "NollieMac"],
    "Apps/Watch/App/Localizable.xcstrings": ["NollieWatch"],
    "Apps/Watch/Widgets/Localizable.xcstrings": ["NollieWatchWidgets"],
    "Extensions/Controls/Localizable.xcstrings": ["NollieControls", "NollieMacControls"],
    "Extensions/NotificationService/Localizable.xcstrings": ["NollieNotificationService", "NollieMacNotificationService"],
    "Extensions/NotificationContent/Localizable.xcstrings": ["NollieNotificationContent"],
}
CORE = "Shared/Core.xcstrings"


def load(path):
    return json.loads((ROOT / path).read_text())


def save(path, catalog):
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    text = json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : "))
    (ROOT / path).write_text(text + "\n")


def stringsdata(derived, target):
    """The .stringsdata files of one target, from the newest build products only."""
    found = []
    for base in derived:
        found += [p for p in Path(base).rglob("*.stringsdata") if f"/{target}.build/" in str(p)]
    return found


def sync(derived):
    for catalog, targets in CATALOGS.items():
        files = []
        for target in targets:
            mine = stringsdata(derived, target)
            if not mine:
                sys.exit(f"No strings found for {target}: build it with SWIFT_EMIT_LOC_STRINGS=YES first.")
            files += mine
        subprocess.run(["xcrun", "xcstringstool", "sync", str(ROOT / catalog), "--stringsdata", *map(str, files)], check=True)
        print(f"synced {catalog} from {len(files)} files")
    sync_core(stringsdata(derived, "NollieCore"))


def sync_core(files):
    """NollieCore's table. Entries are manual, so Xcode does not mark them stale when it builds an app target."""
    if not files:
        sys.exit("No strings found for NollieCore: build with SWIFT_EMIT_LOC_STRINGS=YES on the command line.")
    found = {}
    for f in files:
        for item in json.loads(f.read_text()).get("tables", {}).get("Core", []):
            found.setdefault(item["key"], item.get("comment"))
    catalog = load(CORE)
    strings = catalog["strings"]
    gone = sorted(set(strings) - set(found))
    for key in gone:
        del strings[key]
    for key, comment in found.items():
        entry = strings.setdefault(key, {})
        entry["extractionState"] = "manual"
        if comment:
            entry["comment"] = comment
    save(CORE, catalog)
    print(f"synced {CORE}: {len(found)} strings, {len(gone)} removed" + "".join(f"\n  removed: {k}" for k in gone))


PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(#@\w+@|[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfeEgGcCsSpaA])")


def placeholders(text):
    found, nxt = set(), 1
    for m in PLACEHOLDER.finditer(text.replace("%%", "")):
        pos = int(m.group(1)) if m.group(1) else nxt
        if not m.group(1):
            nxt += 1
        found.add((pos, m.group(2).replace("lld", "ld").replace("ld", "lld")))
    return found


def forms(loc):
    if "stringUnit" in loc:
        u = loc["stringUnit"]
        return [("", u.get("value", ""), u.get("state", ""))]
    if "stringSet" in loc:
        s = loc["stringSet"]
        return [("", v, s.get("state", "")) for v in s.get("values", [])]
    out = []
    for cases in loc.get("variations", {}).values():
        for category, nested in cases.items():
            out += [(category, v, st) for _, v, st in forms(nested)]
    return out


def catalogs():
    skip = {"build", ".git"}
    return sorted(p for p in ROOT.rglob("*.xcstrings") if not skip & set(p.relative_to(ROOT).parts))


def check():
    problems = 0
    for path in catalogs():
        strings = json.loads(path.read_text())["strings"]
        rel = path.relative_to(ROOT)
        counts = {lang: {"missing": 0, "needs_review": 0, "translated": 0} for lang in LANGUAGES}
        for key, entry in strings.items():
            if entry.get("shouldTranslate") is False:
                continue
            locs = entry.get("localizations", {})
            english = forms(locs["en"]) if "en" in locs else [("", key, "")]
            full = placeholders(next((v for c, v, _ in english if c in ("", "other")), key))
            for lang in LANGUAGES:
                found = forms(locs.get(lang, {}))
                if not found:
                    counts[lang]["missing"] += 1
                    continue
                states = {st for _, _, st in found}
                counts[lang]["needs_review" if "needs_review" in states else "translated"] += 1
                for category, value, _ in found:
                    got = placeholders(value)
                    if (got != full) if category in ("", "other") else not got <= full:
                        problems += 1
                        print(f"  placeholders {lang} {rel}: {key!r} -> {value!r}")
                    if "—" in value:
                        problems += 1
                        print(f"  em-dash {lang} {rel}: {value!r}")
        line = ", ".join(f"{lang} {c['translated'] + c['needs_review']}/{len(strings)}"
                         f" ({c['needs_review']} to review{', ' + str(c['missing']) + ' missing' if c['missing'] else ''})"
                         for lang, c in counts.items())
        print(f"{rel}: {line}")
    if problems:
        sys.exit(f"{problems} problems")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "sync":
        sync(sys.argv[2:])
    elif sys.argv[1:] == ["check"]:
        check()
    else:
        sys.exit(__doc__)
