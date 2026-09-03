#!/usr/bin/env bash
# Testtreiber fuer die Skripte in resources/de/firma/ci/.
#
#   test/run-tests.sh
#
# Laeuft ohne Netzwerk. Was mangels Werkzeug nicht geprueft werden kann, wird
# als SKIP gemeldet - der Treiber soll nicht gruen aussehen, wo nichts
# geprueft wurde. Bewusst ohne 'set -e': ein fehlgeschlagener Test soll den
# Rest des Laufs nicht abschneiden.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/resources/de/firma/ci"
FIXTURE="${ROOT}/test/fixture"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
         if [[ $# -gt 1 ]]; then printf '      %s\n' "$2"; fi; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP  %s (%s)\n' "$1" "$2"; }

assert_eq() {   # <name> <erwartet> <ist>
  if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "erwartet [$2], ist [$3]"; fi
}
assert_rc() {   # <name> <erwarteter rc> <ist rc>
  if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "erwartet rc=$2, ist rc=$3"; fi
}
assert_contains() {  # <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else nok "$1" "[$3] fehlt in: $2"; fi
}

# Baut ein Archiv mit PKG-INFO von Hand - ohne Python, damit der Test auch
# ohne setuptools laeuft.
make_sdist() {  # <unterordner> <name> <version> -> Archivpfad auf stdout
  local d="${TMP}/$1"
  mkdir -p "${d}/dist-$3"
  printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$2" "$3" \
    > "${d}/dist-$3/PKG-INFO"
  ( cd "$d" && tar czf archive.tar.gz "dist-$3" )
  printf '%s\n' "${d}/archive.tar.gz"
}

# Legt das Fixture als echtes Git-Repo an: changed-packages.sh fragt git diff.
fixture_repo() {  # -> Pfad auf stdout
  local d="${TMP}/repo"
  rm -rf "$d"; mkdir -p "$d"
  cp -R "${FIXTURE}/." "$d/"
  (
    cd "$d"
    git init -q -b main
    git config user.email test@example.com
    git config user.name Test
    git add -A
    git commit -q -m "fixture"
  ) >/dev/null
  printf '%s\n' "$d"
}

echo "=== Syntax ==="
for f in "$SCRIPTS"/*.sh "${ROOT}/test/run-tests.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"
  else nok "bash -n $(basename "$f")" "$(bash -n "$f" 2>&1 | head -1)"; fi
done

echo
echo "=== sdist-meta.sh ==="
ARCHIVE="$(make_sdist meta 'Mein.Tolles_Paket' '2.1.post1')"
assert_eq "Name aus PKG-INFO" "Mein.Tolles_Paket" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "$ARCHIVE" name)"
assert_eq "Version aus PKG-INFO" "2.1.post1" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "$ARCHIVE" version)"
assert_eq "Default-Feld ist version" "2.1.post1" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "$ARCHIVE")"

OUT="$(bash "$SCRIPTS/sdist-meta.sh" "$ARCHIVE" quatsch 2>&1)"; RC=$?
assert_rc "unbekanntes Feld -> rc 1" 1 "$RC"
assert_contains "unbekanntes Feld -> Meldung" "$OUT" "name' oder 'version"

OUT="$(bash "$SCRIPTS/sdist-meta.sh" "${TMP}/gibtsnicht.tar.gz" 2>&1)"; RC=$?
assert_rc "fehlendes Archiv -> rc 1" 1 "$RC"
assert_contains "fehlendes Archiv -> Meldung" "$OUT" "nicht gefunden"

echo
echo "=== build-sdist.sh ==="
mkdir -p "${TMP}/leer"
OUT="$(cd "$TMP" && bash "$SCRIPTS/build-sdist.sh" gibtsnicht 2>&1)"; RC=$?
assert_rc "kein Verzeichnis -> rc 1" 1 "$RC"
assert_contains "kein Verzeichnis -> Meldung" "$OUT" "kein Verzeichnis"

OUT="$(cd "$TMP" && bash "$SCRIPTS/build-sdist.sh" leer 2>&1)"; RC=$?
assert_rc "ohne Metadaten -> rc 1" 1 "$RC"
assert_contains "ohne Metadaten -> Meldung" "$OUT" "keine Paket-Metadaten"

if python3 -c 'import build' 2>/dev/null || python3 -c 'import setuptools' 2>/dev/null; then
  REPO="$(fixture_repo)"
  ARCH="$(cd "$REPO" && bash "$SCRIPTS/build-sdist.sh" alpha 2>/dev/null)"
  if [[ -f "${REPO}/${ARCH}" ]]; then
    ok "sdist gebaut: $ARCH"
    assert_eq "gebaute sdist: Version" "1.0.0" \
      "$(bash "$SCRIPTS/sdist-meta.sh" "${REPO}/${ARCH}" version)"
  else
    nok "sdist gebaut" "kein Archiv unter ${REPO}/${ARCH}"
  fi
else
  skip "build-sdist.sh Happy Path" "weder python3 -m build noch setuptools vorhanden"
fi

echo
echo "=== publish-pypi.sh ==="
OUT="$(bash "$SCRIPTS/publish-pypi.sh" 2>&1)"; RC=$?
if [[ $RC -ne 0 ]]; then ok "ohne Argument -> rc != 0"; else nok "ohne Argument -> rc != 0" "rc=0"; fi
assert_contains "ohne Argument -> Meldung" "$OUT" "archiv fehlt"

OUT="$(NEXUS_URL= NEXUS_PYPI_HOSTED= NEXUS_USER= NEXUS_PASS= \
       bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"; RC=$?
if [[ $RC -ne 0 ]]; then ok "ohne NEXUS_URL -> rc != 0"; else nok "ohne NEXUS_URL -> rc != 0" "rc=0"; fi
assert_contains "ohne NEXUS_URL -> Meldung" "$OUT" "NEXUS_URL fehlt"

OUT="$(NEXUS_URL=https://nexus.invalid NEXUS_PYPI_HOSTED= NEXUS_USER=u NEXUS_PASS=p \
       bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"; RC=$?
assert_contains "ohne HOSTED-Repo -> Meldung" "$OUT" "NEXUS_PYPI_HOSTED fehlt"

skip "publish-pypi.sh echter Upload" "braucht Netzwerk und ein Nexus - bewusst nicht getestet"

echo
echo "=== Bilanz ==="
printf 'PASS %d  FAIL %d  SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
