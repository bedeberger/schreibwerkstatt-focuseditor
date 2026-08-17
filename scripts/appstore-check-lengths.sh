#!/usr/bin/env bash
#
# appstore-check-lengths.sh — prüft die App-Store-Texte gegen Apples Limits.
#
# Liest AppStore/listing-de.md, AppStore/listing-en.md und AppStore/whats-new.md
# (dort die „Neue Funktionen“-Texte je Version), nimmt jede Überschrift
# der Form `## Titel (max. N)` bzw. `## Title (max N)` samt dem darauf folgenden
# Code-Block und vergleicht dessen Zeichenzahl mit N. Zeichen zählt Apple als
# Unicode-Zeichen (nicht Bytes) — darum Python statt `wc -c`.
#
# Aufruf:  scripts/appstore-check-lengths.sh
# Exit 1, sobald ein Feld über dem Limit liegt.

set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import re, sys, pathlib

files = ["AppStore/listing-de.md", "AppStore/listing-en.md", "AppStore/whats-new.md"]
# `## Untertitel (max. 30)` / `## Subtitle (max 30)` → Limit; danach der erste ```-Block.
head = re.compile(r"^##\s+(.*?)\s*\(max\.?\s*(\d+)[^)]*\).*$", re.M)
fail = 0

for f in files:
    text = pathlib.Path(f).read_text(encoding="utf-8")
    print(f"\n{f}")
    for m in head.finditer(text):
        title, limit = m.group(1), int(m.group(2))
        rest = text[m.end():]
        block = re.search(r"```\n(.*?)\n```", rest, re.S)
        if not block:
            print(f"  ?  {title}: kein Code-Block gefunden")
            fail = 1
            continue
        n = len(block.group(1))
        ok = n <= limit
        fail |= (not ok)
        print(f"  {'OK ' if ok else 'ZU LANG'} {title}: {n}/{limit}")

sys.exit(1 if fail else 0)
PY
