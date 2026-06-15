#!/usr/bin/env bash
# publish-github-release.sh — Notarisiertes .dmg als GitHub-Release-Asset veroeffentlichen.
#
# Der Server (Mutterprojekt) liest das "latest"-Release dieses Repos ueber die
# GitHub-API und bietet das .dmg unter Profil-Einstellungen zum Download an.
# Damit landet jede neue Version automatisch dort — ohne das Binary in git zu legen.
#
# Voraussetzungen:
#   - gh CLI installiert + eingeloggt (gh auth status) mit Schreibrecht aufs Repo
#   - das uebergebene .dmg ist bereits signiert + notarisiert (scripts/release-dmg.sh)
#
# Nutzung:
#   scripts/publish-github-release.sh /Pfad/zu/Focuseditor-1.0.dmg
#   VERSION=1.1 scripts/publish-github-release.sh /Pfad/zu/Focuseditor.dmg
#
# Umgebungsvariablen:
#   VERSION   optional — ueberschreibt die aus dem .app-Bundle gelesene Version.
#             Daraus wird der Release-Tag "v<VERSION>" gebildet.
#   REPO      Default: bedeberger/schreibwerkstatt-focuseditor
#   NOTES     optional — Release-Notiz-Text. Ohne Wert: --generate-notes.

set -euo pipefail

DMG_PATH="${1:?Pfad zum notarisierten .dmg angeben}"
[[ -f "$DMG_PATH" ]] || { echo "FEHLER: .dmg nicht gefunden: $DMG_PATH" >&2; exit 1; }

REPO="${REPO:-bedeberger/schreibwerkstatt-focuseditor}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Version bestimmen --------------------------------------------------------
# Bevorzugt VERSION-Env; sonst CFBundleShortVersionString aus dem frischen
# Release-Build-Produkt (single source: MARKETING_VERSION im Xcode-Projekt).
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  APP_PLIST="$ROOT/build/Build/Products/Release/Focuseditor.app/Contents/Info.plist"
  if [[ -f "$APP_PLIST" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || true)"
  fi
fi
[[ -n "$VERSION" ]] || { echo "FEHLER: Version unbestimmbar — VERSION=… setzen." >&2; exit 1; }
TAG="v$VERSION"

echo "==> Repo:    $REPO"
echo "==> Version: $VERSION  (Tag: $TAG)"
echo "==> Asset:   $DMG_PATH"

# --- gh-Login pruefen ---------------------------------------------------------
gh auth status >/dev/null 2>&1 || { echo "FEHLER: 'gh' nicht eingeloggt (gh auth login)." >&2; exit 1; }

# --- Existiert der Tag bereits? -> sauber abbrechen mit Hinweis ---------------
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "FEHLER: Release '$TAG' existiert bereits." >&2
  echo "        MARKETING_VERSION im Xcode-Projekt erhoehen oder VERSION=… setzen." >&2
  exit 1
fi

# --- Release anlegen + Asset hochladen ---------------------------------------
# Asset-Name stabil halten, damit der Server-Parser robust den .dmg findet.
ASSET_NAME="Focuseditor-$VERSION.dmg"
TMP_ASSET="$(dirname "$DMG_PATH")/$ASSET_NAME"
if [[ "$DMG_PATH" != "$TMP_ASSET" ]]; then
  cp "$DMG_PATH" "$TMP_ASSET"
fi

NOTES_ARGS=(--generate-notes)
if [[ -n "${NOTES:-}" ]]; then
  NOTES_ARGS=(--notes "$NOTES")
fi

echo "==> Lege GitHub-Release an + lade Asset hoch..."
gh release create "$TAG" "$TMP_ASSET" \
  --repo "$REPO" \
  --title "Focuseditor $VERSION" \
  --latest \
  "${NOTES_ARGS[@]}"

echo
echo "==> Fertig. Release veroeffentlicht:"
gh release view "$TAG" --repo "$REPO" --json url,tagName,assets \
  --jq '"  " + .url + "\n  Tag: " + .tagName + "\n  Assets: " + ([.assets[].name] | join(", "))'
echo
echo "    Der Server zieht das 'latest'-Release automatisch — neue Version ist sofort"
echo "    unter Profil-Einstellungen verfuegbar (kein Server-Deploy noetig)."
