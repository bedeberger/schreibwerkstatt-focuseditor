#!/usr/bin/env bash
# mark-changed.sh — PostToolUse-Hook: merkt sich, was seit dem letzten
# Verifikationslauf angefasst wurde, damit der Stop-Hook
# (scripts/hooks/verify-build.sh) die richtigen Checks fährt.
#
# Liest die Hook-Payload (JSON) von stdin und setzt Marker-Dateien:
#   /tmp/swk-focuseditor-swift-pending  → Swift-Quelle geändert  → Test-Suite
#   /tmp/swk-focuseditor-mas-pending    → App-Store-Kanal betroffen → MAS-Build
#
# „App-Store-Kanal betroffen" heißt (CLAUDE.md „Zwei Distributionswege"):
# Projektdatei, eine der beiden Info-Plists, Entitlements, Version.xcconfig,
# etwas unter Update/ — ODER der Edit erwähnt Sparkle überhaupt. Genau diese
# Änderungen können still nur EINEN der beiden Kanäle brechen (fehlender
# `#if SPARKLE`-Guard, Key nur in einem Plist).
#
# Exit-Code immer 0 — ein Hook darf den Tool-Lauf nie blockieren.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

case "$path" in
    *.swift) touch /tmp/swk-focuseditor-swift-pending ;;
esac

case "$path" in
    *project.pbxproj|*/Config/Info*.plist|*.entitlements|*Version.xcconfig|*/Update/*)
        touch /tmp/swk-focuseditor-mas-pending ;;
esac

# Sparkle-Erwähnung im Edit selbst (neuer `#if SPARKLE`-Block, UpdaterController-
# Aufruf in einer beliebigen Datei) — der Pfad allein verrät das nicht.
if printf '%s' "$payload" | grep -qE 'SPARKLE|Sparkle|UpdaterController' 2>/dev/null; then
    touch /tmp/swk-focuseditor-mas-pending
fi

exit 0
