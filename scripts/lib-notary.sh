# lib-notary.sh — gemeinsame Notarisierungs-Helfer (von notarize.sh + release-dmg.sh gesourct).
#
# Erwartet (typisch aus scripts/release.env):
#   NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER   (App-Store-Connect-API-Key, bevorzugt)
#   oder NOTARY_PROFILE                           (Keychain-Profil, Fallback)
#
# Stellt bereit:
#   notary_auth   (Array mit den Auth-Flags für xcrun notarytool)
#   notarize_and_staple <datei>   submit + Status-Polling (robust gg. Netz-Hänger) + stapeln

# Auth-Flags einmal zusammenbauen (API-Key bevorzugt, da keychain-/session-frei).
notary_auth=()
if [[ -n "${NOTARY_KEY:-}" ]]; then
  notary_auth=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID fehlt}" --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER fehlt}")
else
  notary_auth=(--keychain-profile "${NOTARY_PROFILE:-swk-notary}")
fi

# notarize_and_staple <datei>
#   Lädt die Datei hoch (ohne --wait, um die Submission-ID sicher zu bekommen),
#   pollt dann den Status. Transiente Netzfehler (leerer Status) werden toleriert
#   und erneut versucht — anders als notarytool --wait, das beim ersten -1004 abbricht.
notarize_and_staple() {
  local file="$1"
  local poll_secs="${NOTARY_POLL_SECS:-15}"
  local max_polls="${NOTARY_MAX_POLLS:-160}"   # 160 * 15s ≈ 40 min Obergrenze

  # notarytool nimmt nur .zip/.dmg/.pkg — ein nacktes .app vorher zippen.
  # Gestapelt wird am Ende trotzdem das Bundle ("$file"), nicht das Zip.
  local upload="$file" tmpzip=""
  if [[ "$file" == *.app ]]; then
    tmpzip="$(dirname "$file")/$(basename "$file" .app)-notarize.zip"
    echo "==> Packe .app für Upload: $(basename "$tmpzip")"
    ditto -c -k --keepParent "$file" "$tmpzip"
    upload="$tmpzip"
  fi

  echo "==> Sende an Apple-Notarisierung: $(basename "$upload")"
  local sid
  sid=$(xcrun notarytool submit "$upload" "${notary_auth[@]}" 2>&1 \
        | awk -F': ' '/^[[:space:]]*id:/{print $2; exit}')
  if [[ -z "$sid" ]]; then
    echo "FEHLER: keine Submission-ID erhalten (Upload fehlgeschlagen)." >&2
    [[ -n "$tmpzip" ]] && rm -f "$tmpzip"
    return 1
  fi
  echo "    Submission-ID: $sid"

  # Variable bewusst NICHT "status" nennen — das ist in zsh reserviert/read-only.
  local st="" i
  for ((i = 1; i <= max_polls; i++)); do
    sleep "$poll_secs"
    st=$(xcrun notarytool info "$sid" "${notary_auth[@]}" 2>/dev/null \
         | awk -F': ' '/status:/{print $2}')
    if [[ -z "$st" ]]; then
      echo "    [$i] Netz-/Status-Hänger — erneuter Versuch..."
      continue
    fi
    echo "    [$i] Status: $st"
    [[ "$st" != "In Progress" ]] && break
  done

  [[ -n "$tmpzip" ]] && rm -f "$tmpzip"

  if [[ "$st" == "Accepted" ]]; then
    echo "==> Accepted — Ticket ans Bundle heften..."
    xcrun stapler staple "$file"
    xcrun stapler validate "$file"
    return 0
  fi

  echo "FEHLER: Notarisierung nicht erfolgreich (Status: ${st:-unbekannt})." >&2
  echo "        Detail-Log:" >&2
  xcrun notarytool log "$sid" "${notary_auth[@]}" >&2 2>&1 || true
  return 1
}
