#!/usr/bin/env python3 -I
"""Collect the licence of every crate linked into the Nollie Computer helper.

Input: `cargo tree -p cua-driver --target aarch64-apple-darwin -e normal,build --prefix none`
(one "name vX.Y.Z" per line). Licence fields and files come from the vendored crates.
Writes crate-licences.md (a summary, with anything copyleft or unknown flagged) and
THIRD_PARTY_NOTICES.txt (every licence text once) to ship beside NOTICE.txt.

Usage: third-party-notices.py <crates.txt> <vendor-dir> <workspace-crates-dir> <out-dir>
"""
import collections
import glob
import os
import re
import sys

FLAG = re.compile(r"GPL|MPL|EPL|CDDL|FSL|SSPL|BUSL|UNKNOWN|file:", re.I)


def licence_of(cargo_toml):
    if m := re.search(r'^license\s*=\s*"([^"]+)"', cargo_toml, re.M):
        return m.group(1)
    if "license.workspace" in cargo_toml or "license = { workspace" in cargo_toml:
        return "workspace (MIT)"
    if m := re.search(r'^license-file\s*=\s*"([^"]+)"', cargo_toml, re.M):
        return f"file:{m.group(1)}"
    return "UNKNOWN"


def read(path):
    with open(path, errors="replace") as f:
        return f.read()


def main(crates_txt, vendor, workspace, out):
    rows, texts, seen = [], [], set()
    for line in read(crates_txt).splitlines():
        m = re.match(r"^(\S+) v(\S+)", line.strip())
        if not m or m.groups() in seen:
            continue
        seen.add(m.groups())
        name, version = m.groups()
        folder = os.path.join(vendor, f"{name}-{version}")
        local = not os.path.isdir(folder)
        if local:
            folder = os.path.join(workspace, name)
            if not os.path.isdir(folder):
                folder = os.path.join(workspace, "..", "..", "..", "cua", "crates", name)
        toml_path = os.path.join(folder, "Cargo.toml")
        licence = licence_of(read(toml_path) if os.path.exists(toml_path) else "")
        rows.append((name, version, licence, "Cua workspace" if local else "crates.io"))
        if local:
            continue
        files = sorted({*glob.glob(os.path.join(folder, "LICEN[CS]E*")), *glob.glob(os.path.join(folder, "COPYING*")),
                        *glob.glob(os.path.join(folder, "NOTICE*"))})
        body = "\n\n".join(f"--- {os.path.basename(f)} ---\n" + read(f).strip() for f in files if os.path.isfile(f))
        texts.append((f"{name} {version} ({licence})", body or f"(no licence file in the crate; Cargo.toml says {licence})"))

    os.makedirs(out, exist_ok=True)
    counts = collections.Counter(r[2] for r in rows)
    with open(os.path.join(out, "crate-licences.md"), "w") as f:
        f.write(f"# Crates linked into Nollie Computer ({len(rows)})\n\n## Licence expressions\n\n")
        for licence, count in counts.most_common():
            f.write(f"- {count} x `{licence}`{'  (check)' if FLAG.search(licence) else ''}\n")
        f.write("\n## Needs a look\n\n")
        for r in rows:
            if FLAG.search(r[2]):
                f.write(f"- {r[0]} {r[1]}: `{r[2]}` ({r[3]})\n")
    groups = collections.OrderedDict()
    for label, body in texts:
        groups.setdefault(body, []).append(label)
    with open(os.path.join(out, "THIRD_PARTY_NOTICES.txt"), "w") as f:
        f.write("Third-party software in Nollie Computer (Nollie's build of Cua Driver)\n\n")
        for body, labels in groups.items():
            f.write("==== " + "; ".join(labels) + " ====\n" + body + "\n\n")
    flagged = [r for r in rows if FLAG.search(r[2])]
    print(f"{len(rows)} crates; flagged: {len(flagged)}")
    # Only the six unmodified MPL-2.0 UniFFI crates are expected. Anything else stops the build.
    unexpected = [r for r in flagged if not (r[2] == "MPL-2.0" and r[0].startswith("uniffi"))]
    for r in unexpected:
        print(f"Unexpected licence: {r[0]} {r[1]} {r[2]}", file=sys.stderr)
    return 1 if unexpected else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:5]))
