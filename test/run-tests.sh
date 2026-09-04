#!/usr/bin/env bash
# Testtreiber fuer die Skripte in resources/de/firma/ci/.
#
#   test/run-tests.sh
#
# Laeuft ohne Netzwerk. Was mangels Werkzeug nicht geprueft werden kann, wird
# als SKIP gemeldet - der Treiber soll nicht gruen aussehen, wo nichts
# geprueft wurde. Bewusst ohne 'set -e': ein fehlgeschlagener Test soll den
# Rest des Laufs nicht abschneiden.
#
# Ehrlich bleiben (I-4): der Block "vars/pyMonorepo.groovy" unten pinnt Text,
# Reihenfolge einzelner Zeilen und die withEnv/$VAR-Kopplung je Aufrufstelle -
# keine Laufzeitsemantik. Insbesondere die Reihenfolge, in der die Steps
# EINANDER aufrufen (welcher Step vor welchem laeuft), bleibt ungeprueft; das
# zeigt erst ein echter Jenkins-Lauf.
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
  # Absicherung: eine leere Nadel passt mit *""* auf jeden Haystack und waere
  # sonst immer gruen, ohne irgendetwas zu pruefen. Das muss als Fehler
  # gemeldet werden, nicht als stiller Treffer.
  if [[ -z "$3" ]]; then nok "$1" "Nadel ist leer - Assertion prueft nichts"; return; fi
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

# Wie make_sdist, aber die PKG-INFO wird per Schleife (ohne Python) auf
# deutlich > 64 KB aufgepolstert - so gross, wie eine reale sdist mit langer
# 'long_description' werden kann. Deckt I-1 ab: 'tar tzf'/'tar xzOf' schrieben
# bei einer derart grossen PKG-INFO frueher in eine bereits geschlossene Pipe
# ("Write error: Broken pipe", rc 1), sobald der Leser dahinter (grep -q/-m1,
# frueher 'head -40'/'head -1') vor dem Ende der Tar-Ausgabe aussteigt.
# mit_changelog=1 haengt zusaetzlich viele weitere Zeilen an, die selbst wie
# "Version: "-Treffer aussehen (simuliert ein Changelog in der Description) -
# das deckt zusaetzlich den Fall ab, in dem nicht die Datei, sondern das
# sed-Ergebnis selbst > 64 KB wird (ein 'sed | head -1' danach waere genauso
# betroffen wie 'tar | grep/head' davor - deshalb beendet sich sed in
# build-sdist.sh/sdist-meta.sh nach dem ersten Treffer per 'q' selbst).
make_big_sdist() {  # <unterordner> <name> <version> [mit_changelog] -> Archivpfad auf stdout
  local d="${TMP}/$1" name="$2" ver="$3" with_changelog="${4:-0}" i
  mkdir -p "${d}/dist-${ver}"
  {
    printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$name" "$ver"
    i=0
    while [[ $i -lt 1200 ]]; do
      printf 'Description: filler filler filler filler filler filler filler filler line %d\n' "$i"
      i=$((i+1))
    done
    if [[ "$with_changelog" == 1 ]]; then
      i=0
      while [[ $i -lt 3000 ]]; do
        printf 'Version: %s.dev%d - Changelog-Eintrag\n' "$ver" "$i"
        i=$((i+1))
      done
    fi
  } > "${d}/dist-${ver}/PKG-INFO"
  ( cd "$d" && tar czf archive.tar.gz "dist-${ver}" )
  printf '%s\n' "${d}/archive.tar.gz"
}

# Stub fuer python3: bedient die drei Aufrufe, die build-sdist.sh absetzt
# ('-c import build', '-m build --sdist --outdir <dir>' und den Fallback
# 'setup.py --quiet sdist --dist-dir <dir>'), und legt im outdir ein Archiv
# wie make_sdist ab. Name/Version kommen aus STUB_NAME/STUB_VERSION, damit der
# Test den Fall "Ordner != Paketname" abdeckt.
# STUB_BIG_PKGINFO=1 polstert die erzeugte PKG-INFO wie make_big_sdist auf
# > 64 KB auf - fuer den I-1-Test, der den kompletten build-sdist.sh-Pfad
# (nicht nur sdist-meta.sh direkt) mit einer grossen sdist durchlaufen laesst.
# STUB_NO_BUILD=1 laesst 'import build' fehlschlagen (rc 1), damit
# build-sdist.sh auf den setup.py-Fallback (M-6b) umschaltet.
#
# Grund: der Happy Path lief bisher nur, wenn python-build oder setuptools
# installiert waren, und wurde sonst als SKIP gemeldet. So blieb der komplette
# Codepfad NACH dem Build (Archiv einsammeln, PKG-INFO pruefen, mv, Pfad
# ausgeben) auf Entwicklerrechnern ungetestet - und ein 'mapfile' (Bash >= 4)
# fiel auf dem Stock-Bash 3.2 von macOS nie auf. Mit dem Stub laeuft dieser
# Teil immer, ganz ohne Python. Der Stub selbst muss dabei natuerlich auch
# bash-3.2-tauglich sein (tr statt ${var,,}).
make_python_stub() {  # -> Verzeichnis fuer PATH auf stdout
  local d="${TMP}/stub-bin"
  mkdir -p "$d"
  cat > "${d}/python3" <<'STUB'
#!/usr/bin/env bash
# python3-Stub aus test/run-tests.sh (make_python_stub) - kein echtes Python.
set -euo pipefail

# M-6c: der Stub prueft, dass er tatsaechlich IM Paketordner steht, statt das
# einfach anzunehmen. Ohne diese Pruefung wuerde ein versehentlich entferntes
# 'cd "$PKG"' in build-sdist.sh unbemerkt bleiben - der Stub haette trotzdem
# "funktioniert", nur im falschen Verzeichnis. Gilt nur fuer die beiden
# Aufrufe, die laut build-sdist.sh im Paketordner laufen sollen (-m build,
# setup.py sdist) - nicht fuer 'python3 -c "import build"': das laeuft in
# build-sdist.sh VOR dem 'cd "$PKG"', im Checkout-Wurzelverzeichnis.
check_cwd() {
  [[ -f setup.py || -f setup.cfg || -f pyproject.toml ]] || {
    echo "python3-stub: kein setup.py/setup.cfg/pyproject.toml im aktuellen Verzeichnis ($(pwd)) - build-sdist.sh haette hierher 'cd' sollen" >&2
    exit 2
  }
}

case "${1:-}" in
  -c) [[ "${STUB_NO_BUILD:-0}" != 1 ]] || exit 1   # 'import build' schlaegt fehl -> setup.py-Fallback
      exit 0 ;;   # 'import build' -> tut so, als waere python-build installiert
  -m) check_cwd
      [[ "${2:-}" == build && "${3:-}" == --sdist && "${4:-}" == --outdir && -n "${5:-}" ]] \
        || { echo "python3-stub: unerwartete Argumente: $*" >&2; exit 2; }
      out="$5" ;;
  setup.py) check_cwd
      [[ "${2:-}" == --quiet && "${3:-}" == sdist && "${4:-}" == --dist-dir && -n "${5:-}" ]] \
        || { echo "python3-stub: unerwartete Argumente (setup.py-Fallback): $*" >&2; exit 2; }
      out="$5" ;;
  *)  echo "python3-stub: unerwarteter Aufruf: $*" >&2; exit 2 ;;
esac
name="${STUB_NAME:?}"; ver="${STUB_VERSION:?}"
# Archivname wie bei einer echten sdist normalisiert (PEP 625): klein, '.'/'-' -> '_'.
base="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr '.-' '__')-${ver}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "${work}/${base}"
{
  printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$name" "$ver"
  if [[ "${STUB_BIG_PKGINFO:-0}" == 1 ]]; then
    i=0
    while [[ $i -lt 1200 ]]; do
      printf 'Description: filler filler filler filler filler filler filler filler line %d\n' "$i"
      i=$((i+1))
    done
  fi
} > "${work}/${base}/PKG-INFO"
tar czf "${out}/${base}.tar.gz" -C "$work" "$base"
echo "Successfully built ${base}.tar.gz"
STUB
  chmod +x "${d}/python3"
  printf '%s\n' "$d"
}

# curl-Stub: kein echtes curl. Schreibt Argumente und stdin mit, damit die Tests
# pruefen koennen, dass die Zugangsdaten NICHT in argv stehen, und antwortet mit
# einem per Umgebung gesteuerten HTTP-Status.
#   STUB_DIR        Verzeichnis fuer curl-args / curl-stdin (Pflicht)
#   STUB_HTTP       HTTP-Status, den der Upload-Aufruf meldet (Default 204)
#   STUB_BODY       Body, den der Upload-Aufruf in die --output-Datei schreibt
#   STUB_CURL_RC    Exit-Code des Stubs (Default 0) - simuliert Netzfehler
#   STUB_CURL_STDERR Text, den der Stub bei STUB_CURL_RC != 0 auf stderr
#                    schreibt (I-3: deckt den Diagnosekanal ab, auf dem der
#                    Umbruch-Guard begruendet ist - 'cat "$ERR_FILE" >&2' im
#                    Skript muss diesen Text tatsaechlich ausgeben)
#   STUB_REPOS_JSON JSON, das der Repo-Typ-Check-Aufruf auf stdout liefert
make_curl_stub() {  # -> Verzeichnis fuer PATH auf stdout
  local d="${TMP}/curl-stub-bin"
  mkdir -p "$d"
  cat > "${d}/curl" <<'STUB'
#!/usr/bin/env bash
# curl-Stub aus test/run-tests.sh (make_curl_stub).
set -u
: "${STUB_DIR:?STUB_DIR fehlt}"
printf '%s\n' "$@" >> "${STUB_DIR}/curl-args"
cat >> "${STUB_DIR}/curl-stdin"

# Zwei Aufrufarten unterscheiden: der Upload nutzt --output <datei>, der
# Repo-Typ-Check nicht.
out=""
prev=""
write_out=0
for a in "$@"; do
  if [[ "$prev" == "--output" ]]; then out="$a"; fi
  if [[ "$a" == "--write-out" ]]; then write_out=1; fi
  prev="$a"
done

if [[ -z "$out" ]]; then
  # Repo-Typ-Check
  printf '%s' "${STUB_REPOS_JSON:-[]}"
  exit 0
fi

printf '%s' "${STUB_BODY:-}" > "$out"
# Den Status nur drucken, wenn das Skript ihn wirklich per --write-out abholt -
# sonst bliebe ein versehentlich gestrichenes --write-out unbemerkt gruen.
if [[ "$write_out" == 1 ]]; then
  printf '%s' "${STUB_HTTP:-204}"
fi
# I-3: im Fehlerfall etwas auf stderr schreiben - so wie echtes curl mit
# --show-error einen Diagnosetext liefert. Ohne das bliebe unbemerkt, wenn
# 'cat "$ERR_FILE" >&2' oder '--show-error' aus dem Skript verschwindet.
if [[ "${STUB_CURL_RC:-0}" != 0 && -n "${STUB_CURL_STDERR:-}" ]]; then
  printf '%s' "${STUB_CURL_STDERR}" >&2
fi
exit "${STUB_CURL_RC:-0}"
STUB
  chmod +x "${d}/curl"
  printf '%s\n' "$d"
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

# I-1: PKG-INFO > 64 KB darf den Broken-Pipe-Abbruch nicht mehr ausloesen
# (frueher: 'tar xzOf ... | sed -n ... | head -1' unter 'set -o pipefail').
BIG_ARCHIVE="$(make_big_sdist gross 'Grosses.Paket' '3.4.5')"
OUT="$(bash "$SCRIPTS/sdist-meta.sh" "$BIG_ARCHIVE" name 2>&1)"; RC=$?
assert_rc "grosse PKG-INFO (>64 KB) -> rc 0" 0 "$RC"
assert_eq "grosse PKG-INFO -> Name" "Grosses.Paket" "$OUT"
assert_eq "grosse PKG-INFO -> Version" "3.4.5" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "$BIG_ARCHIVE" version 2>/dev/null)"

# Zusatzfall: eine zweite, spaeter im Text beginnende "Version: "-Zeile (z. B.
# ein Changelog in der Description) darf den ersten (richtigen) Treffer nicht
# verdecken UND darf nicht selbst zum Broken-Pipe-Abbruch fuehren, wenn das
# sed-Ergebnis (alle Treffer) fuer sich genommen schon > 64 KB waere.
BIG_ARCHIVE_CL="$(make_big_sdist gross-changelog 'Anderes.Paket' '7.0' 1)"
OUT="$(bash "$SCRIPTS/sdist-meta.sh" "$BIG_ARCHIVE_CL" version 2>&1)"; RC=$?
assert_rc "grosse PKG-INFO mit Changelog-Zeilen -> rc 0" 0 "$RC"
assert_eq "grosse PKG-INFO mit Changelog-Zeilen -> erster Treffer gewinnt" "7.0" "$OUT"

echo
echo "=== build-sdist.sh ==="
mkdir -p "${TMP}/leer"
OUT="$(cd "$TMP" && bash "$SCRIPTS/build-sdist.sh" gibtsnicht 2>&1)"; RC=$?
assert_rc "kein Verzeichnis -> rc 1" 1 "$RC"
assert_contains "kein Verzeichnis -> Meldung" "$OUT" "kein Verzeichnis"

OUT="$(cd "$TMP" && bash "$SCRIPTS/build-sdist.sh" leer 2>&1)"; RC=$?
assert_rc "ohne Metadaten -> rc 1" 1 "$RC"
assert_contains "ohne Metadaten -> Meldung" "$OUT" "keine Paket-Metadaten"

# Happy Path mit Stub-Backend: laeuft IMMER (siehe make_python_stub). Der
# Stub-Pfad steht nur fuer diesen Aufruf vorn im PATH.
STUB_BIN="$(make_python_stub)"
REPO="$(fixture_repo)"
OUT="$(cd "$REPO" && PATH="${STUB_BIN}:${PATH}" STUB_NAME='Mein.Tolles_Paket' STUB_VERSION='2.1.post1' \
       bash "$SCRIPTS/build-sdist.sh" alpha 2>"${TMP}/stub-build.err")"; RC=$?
assert_rc "Stub-Backend: rc 0" 0 "$RC"
assert_eq "Stub-Backend: Archivpfad auf stdout (aus Metadaten, nicht Ordnername)" \
  "dist/mein_tolles_paket-2.1.post1.tar.gz" "$OUT"
if [[ -n "$OUT" && -f "${REPO}/${OUT}" ]]; then ok "Stub-Backend: Archiv liegt unter dist/"
else nok "Stub-Backend: Archiv liegt unter dist/" "kein Archiv unter ${REPO}/${OUT}"; fi
assert_eq "Stub-Backend: Version aus gebauter sdist" "2.1.post1" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "${REPO}/${OUT}" version 2>/dev/null)"
assert_contains "Stub-Backend: Log meldet Ordner -> Paketname" \
  "$(cat "${TMP}/stub-build.err")" "Ordner 'alpha' -> Mein.Tolles_Paket 2.1.post1"
assert_eq "Stub-Backend: Staging-Verzeichnis aufgeraeumt" "" \
  "$(ls -A "${REPO}/dist" | grep '^\.build-' || true)"

# I-1 durch den kompletten build-sdist.sh-Pfad: der Stub legt hier eine
# PKG-INFO > 64 KB ins gebaute Archiv (STUB_BIG_PKGINFO=1), und build-sdist.sh
# muss trotzdem durchlaufen - frueher brach 'tar xzOf ... | head -40' (Z. 63
# vor dem Fix) mit "Write error: Broken pipe" ab.
REPO="$(fixture_repo)"
OUT="$(cd "$REPO" && PATH="${STUB_BIN}:${PATH}" STUB_NAME='Grosses.Paket' STUB_VERSION='9.9' \
       STUB_BIG_PKGINFO=1 \
       bash "$SCRIPTS/build-sdist.sh" alpha 2>"${TMP}/stub-big-build.err")"; RC=$?
assert_rc "Stub-Backend, grosse PKG-INFO (>64 KB): rc 0" 0 "$RC"
assert_eq "Stub-Backend, grosse PKG-INFO: Archivpfad auf stdout" \
  "dist/grosses_paket-9.9.tar.gz" "$OUT"
assert_eq "Stub-Backend, grosse PKG-INFO: Version aus gebauter sdist" "9.9" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "${REPO}/${OUT}" version 2>/dev/null)"
assert_contains "Stub-Backend, grosse PKG-INFO: Log meldet Ordner -> Paketname" \
  "$(cat "${TMP}/stub-big-build.err")" "Ordner 'alpha' -> Grosses.Paket 9.9"

# M-6b: der setup.py-Fallback (build-sdist.sh Z. 34-36, wenn 'python3 -c
# "import build"' fehlschlaegt) war bisher von keinem Test beruehrt - der
# Stub beantwortete '-c' immer mit 0. STUB_NO_BUILD=1 laesst den Stub '-c'
# mit rc 1 beantworten, build-sdist.sh muss dann auf 'setup.py --quiet sdist
# --dist-dir' umschalten (vom Stub separat bedient, siehe make_python_stub).
REPO="$(fixture_repo)"
OUT="$(cd "$REPO" && PATH="${STUB_BIN}:${PATH}" STUB_NAME='Fallback.Paket' STUB_VERSION='4.2' \
       STUB_NO_BUILD=1 \
       bash "$SCRIPTS/build-sdist.sh" alpha 2>"${TMP}/stub-fallback-build.err")"; RC=$?
assert_rc "setup.py-Fallback: rc 0" 0 "$RC"
assert_eq "setup.py-Fallback: Archivpfad auf stdout" \
  "dist/fallback_paket-4.2.tar.gz" "$OUT"
assert_contains "setup.py-Fallback: Hinweis auf stderr" \
  "$(cat "${TMP}/stub-fallback-build.err")" "nutze 'setup.py sdist'"
assert_eq "setup.py-Fallback: Version aus gebauter sdist" "4.2" \
  "$(bash "$SCRIPTS/sdist-meta.sh" "${REPO}/${OUT}" version 2>/dev/null)"

# M-6c: der Stub prueft jetzt das cwd (siehe make_python_stub/check_cwd) -
# das faengt ein versehentlich entferntes 'cd "$PKG"' in build-sdist.sh.
# Gegenprobe hier direkt gefuehrt: build-sdist.sh in eine Kopie ohne das
# 'cd "$PKG"' im -m-Aufruf patchen, zeigen, dass der Stub das als Fehler
# erkennt (statt still im falschen Verzeichnis "erfolgreich" zu sein), dann
# nichts weiter - die Kopie ist nur fuer diesen einen Aufruf da.
PATCHED="${TMP}/build-sdist-ohne-cd.sh"
sed 's/( cd "\$PKG" && python3 -m build --sdist --outdir "\$STAGE" ) >&2/python3 -m build --sdist --outdir "$STAGE" >\&2/' \
  "$SCRIPTS/build-sdist.sh" > "$PATCHED"
if ! diff -q "$SCRIPTS/build-sdist.sh" "$PATCHED" >/dev/null; then
  OUT="$(cd "$REPO" && PATH="${STUB_BIN}:${PATH}" STUB_NAME='Cwd.Paket' STUB_VERSION='1.1' \
         bash "$PATCHED" alpha 2>&1)"; RC=$?
  assert_rc "Gegenprobe: entferntes 'cd \$PKG' wird vom Stub erkannt -> rc 2" 2 "$RC"
  assert_contains "Gegenprobe: Stub meldet falsches Verzeichnis" "$OUT" \
    "build-sdist.sh haette hierher 'cd' sollen"
else
  nok "Gegenprobe: 'cd \$PKG' im sed-Patch gefunden und entfernt" \
    "sed-Muster hat nicht gegriffen - Gegenprobe ungueltig, bitte Muster pruefen"
fi

# Zusaetzlich mit echtem Backend, wenn eines da ist. Der Stub prueft nur den
# Bash-Teil; erst hier zeigt sich, ob der Aufruf von python-build/setuptools
# selbst stimmt. Aktivieren mit: python3 -m pip install --user build
if python3 -c 'import build' 2>/dev/null || python3 -c 'import setuptools' 2>/dev/null; then
  REPO="$(fixture_repo)"
  ARCH="$(cd "$REPO" && bash "$SCRIPTS/build-sdist.sh" alpha 2>/dev/null)"; RC=$?
  assert_rc "echtes Backend: rc 0" 0 "$RC"
  if [[ -n "$ARCH" && -f "${REPO}/${ARCH}" ]]; then
    ok "echtes Backend: sdist gebaut: $ARCH"
    assert_eq "echtes Backend: Version aus gebauter sdist" "1.0.0" \
      "$(bash "$SCRIPTS/sdist-meta.sh" "${REPO}/${ARCH}" version)"
  else
    nok "echtes Backend: sdist gebaut" "kein Archiv unter ${REPO}/${ARCH}"
  fi
else
  skip "build-sdist.sh mit echtem Backend" "python-build/setuptools fehlen (Stub-Backend oben deckt den Bash-Teil ab; 'python3 -m pip install --user build' aktiviert diesen Test)"
fi

echo
echo "=== publish-pypi.sh ==="
OUT="$(bash "$SCRIPTS/publish-pypi.sh" 2>&1)"; RC=$?
assert_rc "ohne Argument -> rc 1" 1 "$RC"
assert_contains "ohne Argument -> Meldung" "$OUT" "archiv fehlt"

OUT="$(NEXUS_URL= NEXUS_PYPI_HOSTED= NEXUS_USER= NEXUS_PASS= \
       bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"; RC=$?
assert_rc "ohne NEXUS_URL -> rc 1" 1 "$RC"
assert_contains "ohne NEXUS_URL -> Meldung" "$OUT" "NEXUS_URL fehlt"

OUT="$(NEXUS_URL=https://nexus.invalid NEXUS_PYPI_HOSTED= NEXUS_USER=u NEXUS_PASS=p \
       bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"; RC=$?
# M-6d: rc-Assertion nachgezogen, analog zu den zwei Nachbarn oben (ohne
# Argument, ohne NEXUS_URL) - fehlte hier bisher grundlos.
assert_rc "ohne HOSTED-Repo -> rc 1" 1 "$RC"
assert_contains "ohne HOSTED-Repo -> Meldung" "$OUT" "NEXUS_PYPI_HOSTED fehlt"

echo
echo "=== changed-packages.sh ==="
REPO="$(fixture_repo)"
RUN="bash $SCRIPTS/changed-packages.sh"

# Nur alpha angefasst
( cd "$REPO" && echo "x" >> alpha/neu.py && git add -A && git commit -q -m "alpha" )
assert_eq "nur alpha geaendert" "alpha" \
  "$(cd "$REPO" && $RUN HEAD~1)"

# gamma ist kein Paket, docs auch nicht
( cd "$REPO" && echo "x" >> gamma/README.md && echo "y" >> docs/index.md \
  && git add -A && git commit -q -m "kein paket" )
assert_eq "nur Nicht-Pakete geaendert" "" \
  "$(cd "$REPO" && $RUN HEAD~1)"

# I-2: ein Top-Level-Ordner mit nur __init__.py (+ einer weiteren .py-Datei)
# ist seit der Angleichung an build-sdist.sh KEIN Paket mehr - build-sdist.sh
# kann daraus ohnehin keine sdist bauen (weder setup.py, setup.cfg noch
# pyproject.toml). Aenderung darin darf deshalb nicht gemeldet werden.
( cd "$REPO" && echo "def noop2(): pass" >> common/util.py \
  && git add -A && git commit -q -m "common" )
assert_eq "reiner __init__.py-Ordner ist kein Paket (I-2)" "" \
  "$(cd "$REPO" && $RUN HEAD~1)"

# beta und alpha zusammen, sortiert
( cd "$REPO" && echo "x" >> beta/pyproject.toml && echo "x" >> alpha/neu.py \
  && git add -A && git commit -q -m "beide" )
assert_eq "alpha und beta, sortiert" "alpha
beta" "$(cd "$REPO" && $RUN HEAD~1)"

# Jenkinsfile geaendert -> alles bauen
( cd "$REPO" && echo "// x" >> Jenkinsfile && git add -A && git commit -q -m "jenkinsfile" )
assert_eq "Jenkinsfile geaendert -> alles" "alpha
beta" "$(cd "$REPO" && $RUN HEAD~1 2>/dev/null)"

# ci/ geaendert -> alles bauen
( cd "$REPO" && mkdir -p ci && echo "x" > ci/alt.sh && git add -A && git commit -q -m "ci" )
assert_eq "ci/ geaendert -> alles" "alpha
beta" "$(cd "$REPO" && $RUN HEAD~1 2>/dev/null)"

# Leere Basis -> alles bauen
assert_eq "leere Basis -> alles" "alpha
beta" "$(cd "$REPO" && $RUN '' 2>/dev/null)"

# Unbrauchbare Basis -> alles bauen, nicht abbrechen
OUT="$(cd "$REPO" && $RUN deadbeefdeadbeef 2>/dev/null)"; RC=$?
assert_rc "unbrauchbare Basis -> rc 0" 0 "$RC"
assert_eq "unbrauchbare Basis -> alles" "alpha
beta" "$OUT"

# PACKAGES ersetzt die Auto-Erkennung
assert_eq "PACKAGES-Override" "gamma" \
  "$(cd "$REPO" && PACKAGES='gamma' $RUN '' 2>/dev/null)"

# Hinweise gehen nach stderr, nicht nach stdout
assert_contains "Hinweis auf stderr" \
  "$(cd "$REPO" && $RUN '' 2>&1 >/dev/null)" "baue alle Pakete"

# Umlaut in Dateiname darf das Paket nicht verschlucken. git quotet
# Nicht-ASCII-Pfade ohne core.quotepath=false in Anfuehrungszeichen; ohne
# den Fix macht "cut -d/ -f1" daraus '"alpha' statt 'alpha', und das Paket
# faellt lautlos aus der Ausgabe.
( cd "$REPO" && echo "x" > "alpha/übersetzung.txt" && git add -A && git commit -q -m "umlaut" )
assert_eq "Umlaut-Datei wird gemeldet" "alpha" \
  "$(cd "$REPO" && $RUN HEAD~1)"

# M-6a: '--no-renames' war bisher unbelegt. Ohne das Flag erkennt git
# "Datei woanders hin verschoben, Inhalt gleich" per Default als Rename und
# zeigt bei 'diff --name-only' nur den NEUEN Pfad - alpha wuerde eine Datei
# verlieren, ohne als geaendert zu gelten.
( cd "$REPO" && git mv alpha/neu.py beta/neu.py && git commit -q -m "verschoben" )
assert_eq "git mv meldet Quell- UND Zielpaket (--no-renames)" "alpha
beta" "$(cd "$REPO" && $RUN HEAD~1)"

# Gegenprobe direkt hier gefuehrt (nicht nur manuell, siehe Bericht): eine
# Kopie ohne '--no-renames' darf 'alpha' fuer denselben Commit NICHT mehr
# melden.
PATCHED_NR="${TMP}/changed-packages-ohne-no-renames.sh"
sed 's/git -c core.quotepath=false diff --no-renames --name-only/git -c core.quotepath=false diff --name-only/' \
  "$SCRIPTS/changed-packages.sh" > "$PATCHED_NR"
if ! diff -q "$SCRIPTS/changed-packages.sh" "$PATCHED_NR" >/dev/null; then
  assert_eq "Gegenprobe: ohne --no-renames faellt 'alpha' lautlos weg" "beta" \
    "$(cd "$REPO" && bash "$PATCHED_NR" HEAD~1)"
else
  nok "Gegenprobe: '--no-renames' im sed-Patch gefunden und entfernt" \
    "sed-Muster hat nicht gegriffen - Gegenprobe ungueltig, bitte Muster pruefen"
fi

# PACKAGES mit Sonderzeichen darf nicht durch das globale 'shopt -s nullglob'
# des Skripts verschwinden. Leere Basis, damit direkt all_packages() greift
# und kein anderer Codepfad das Ergebnis verfaelscht.
assert_eq "PACKAGES mit Sonderzeichen bleibt erhalten" "nomatch[x]" \
  "$(cd "$REPO" && PACKAGES='nomatch[x]' $RUN '' 2>/dev/null)"

# PACKAGES mit Glob-Zeichen muss literal bleiben, nicht expandiert werden -
# PACKAGES ist eine FESTE Liste, kein Muster.
assert_eq "PACKAGES mit Glob-Zeichen bleibt literal" "al*" \
  "$(cd "$REPO" && PACKAGES='al*' $RUN '' 2>/dev/null)"

# Schnittmenge mit echter Basis: der leere-Basis-Zweig oben umgeht die
# Filterschleife komplett (all_packages() geht dort ungefiltert durch). Erst
# mit echter Basis und mehreren PACKAGES-Eintraegen, von denen nur einer
# tatsaechlich geaendert wurde, wird die Schnittmenge wirklich geprueft.
( cd "$REPO" && echo "x" >> alpha/neu.py && git add -A && git commit -q -m "alpha fuer packages" )
assert_eq "PACKAGES-Schnittmenge mit echter Basis" "alpha" \
  "$(cd "$REPO" && PACKAGES='alpha beta gamma' $RUN HEAD~1 2>/dev/null)"

# I-2: setup.cfg allein muss als Paketkriterium reichen (build-sdist.sh kann
# damit bauen). Eigenes, isoliertes Mini-Repo statt des Haupt-Fixtures, damit
# kein zusaetzlicher Paketordner die "alles bauen"-Assertions oben
# verfaelscht.
SETUPCFG_REPO="${TMP}/setupcfg-repo"
mkdir -p "${SETUPCFG_REPO}/nurcfg"
printf '[metadata]\nname = nurcfg\n' > "${SETUPCFG_REPO}/nurcfg/setup.cfg"
(
  cd "$SETUPCFG_REPO"
  git init -q -b main
  git config user.email test@example.com
  git config user.name Test
  git add -A
  git commit -q -m "init"
  echo "version = 1.0" >> nurcfg/setup.cfg
  git add -A
  git commit -q -m "aenderung an setup.cfg"
) >/dev/null
assert_eq "setup.cfg allein wird als Paket erkannt" "nurcfg" \
  "$(cd "$SETUPCFG_REPO" && bash "$SCRIPTS/changed-packages.sh" HEAD~1)"

echo
echo "=== vars/pyMonorepo.groovy ==="
GROOVY="${ROOT}/vars/pyMonorepo.groovy"
if [[ -f "$GROOVY" ]]; then
  ok "vars/pyMonorepo.groovy vorhanden"

  # Kommentare raus, sonst zaehlen Beispiele im Kopfkommentar mit. Quoting-
  # bewusst (I-3): 'sed -E s#//.*$##' schnitt bisher auch '//' MITTEN in
  # einem String-Literal ab (z.B. eine URL in einem Shell-Kommentar innerhalb
  # eines sh-Scripts) - der Rest der Zeile inklusive schliessendem Quote fiel
  # weg, und Test 7 (Injection-Disziplin) sah danach ein unquotiertes
  # Fragment, das seine eigenen Muster nicht mehr traf, statt der eigentlich
  # noch offenen (jetzt unsichtbaren) Interpolation. Deshalb zeichenweise
  # durchgehen, den Quote-Zustand (einfach/doppelt, mit \-Escape) mitfuehren
  # und '//' nur AUSSERHALB von Quotes als Kommentar werten. Rein
  # zeilenbasiert - die Datei hat keine mehrzeiligen String-Literale.
  CODE="$(awk -v sq="'" '
    {
      line = $0; out = ""; insq = 0; indq = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (!insq && !indq && c == "/" && i < n && substr(line, i + 1, 1) == "/") { break }
        if (c == "\\" && (insq || indq) && i < n) {
          out = out c substr(line, i + 1, 1); i += 2; continue
        }
        if (!indq && c == sq) { insq = !insq }
        else if (!insq && c == "\"") { indq = !indq }
        out = out c; i++
      }
      print out
    }
  ' "$GROOVY")"

  # Schneidet den Rumpf einer Methode/eines Blocks heraus: von der ersten
  # Zeile, die <nadel> enthaelt, bis zu der Zeile, auf der die ab dort
  # gezaehlte Klammertiefe wieder auf 0 faellt - funktioniert fuer einzeilige
  # Rumpfe (private String libDir() { return '...' }) genauso wie fuer
  # mehrzeilige. Die folgenden Tests pruefen damit den tatsaechlichen
  # Methodenkoerper statt irgendeine Fundstelle in der ganzen Datei - eine
  # Mutation *innerhalb* einer Methode kann sich nicht mehr hinter einer
  # zufaelligen Fundstelle anderswo verstecken (C-1, I-1, I-2).
  step_body() {  # <nadel>
    awk -v pat="$1" '
      BEGIN { grab = 0; depth = 0 }
      grab == 0 && index($0, pat) > 0 { grab = 1 }
      grab == 1 {
        print
        depth += gsub(/\{/, "{") - gsub(/\}/, "}")
        if (depth <= 0) exit
      }
    ' <<<"$CODE"
  }

  # 1) Skriptliste in install() == vorhandene Skripte
  NAMES_LINE="$(grep -oE "List names = \[[^]]*\]" <<<"$CODE")"
  NAMED="$(grep -oE "'[A-Za-z][A-Za-z0-9_.-]*\.sh'" <<<"$NAMES_LINE" | tr -d "'" | sort -u)"
  HAVE="$(cd "$SCRIPTS" && ls *.sh | sort -u)"
  assert_eq "install()-Liste == vorhandene Skripte" "$HAVE" "$NAMED"

  # 2) libraryResource: Pfad und Encoding. M-3: auf den vollen Aufruf scharf
  #    (nicht nur das Praefix des Pfads, das auch ein woanders zusammen-
  #    gebauter String erfuellen wuerde).
  LR="$(grep -oE 'libraryResource\([^)]*\)' <<<"$CODE")"
  assert_contains "libraryResource-Pfad ist de/firma/ci/\${n}" "$LR" 'resource: "de/firma/ci/${n}"'
  assert_contains "libraryResource liest mit encoding UTF-8" "$LR" "encoding: 'UTF-8'"

  # 3) Zielverzeichnis mit fuehrendem Punkt. M-2: Rumpf schneiden statt
  #    starrem Einzeiler-Muster, damit ein Umbruch in libDir() den Test nicht
  #    blind rot macht, ohne dass sich etwas Relevantes geaendert hat.
  LIBDIR_BODY="$(step_body 'private String libDir()')"
  LIBDIR="$(grep -oE "return '[^']*'" <<<"$LIBDIR_BODY" | head -1 | sed -E "s/return '([^']*)'/\1/")"
  if [[ -n "$LIBDIR" && "$LIBDIR" == .* ]]; then ok "libDir() beginnt mit einem Punkt ($LIBDIR)"
  else nok "libDir() beginnt mit einem Punkt" "ist [$LIBDIR]"; fi

  # 4) Genau eine sh-Aufrufstelle je Skript (Steps sind Single-Source)
  CALLS="$(grep -oE '\$CI_LIB_DIR/[A-Za-z][A-Za-z0-9_.-]*\.sh' <<<"$CODE" | sed -E 's#.*/##' | sort)"
  CALL_COUNTS="$(printf '%s\n' "$CALLS" | uniq -c | awk '{printf "%s: %s\n", $2, $1}' | sort)"
  EXPECTED_COUNTS=$'build-sdist.sh: 1\nchanged-packages.sh: 1\npublish-pypi.sh: 1\nsdist-meta.sh: 1'
  assert_eq "genau eine sh-Aufrufstelle je Skript" "$EXPECTED_COUNTS" "$CALL_COUNTS"

  # 5) Jede oeffentliche Methode existiert (Signatur am Zeilenanfang)
  for SIG in 'def call(Closure body)' 'String install()' \
             'List changedPackages(String base)' 'List changedPackages(String base, String packages)' \
             'String buildSdist(String pkg)' 'String meta(String archive, String field)' \
             'void publish(Map args)' 'void cleanup()'; do
    if grep -qF "$SIG" <<<"$CODE"; then ok "Methode vorhanden: $SIG"
    else nok "Methode vorhanden: $SIG" "nicht gefunden"; fi
  done

  # 6) Kein Default-Parameter (CPS: synthetische Ueberladung). M-4:
  #    [[:space:]] statt \s - BSD-grep/-E kennt kein Perl-\s.
  DEFAULTS="$(grep -nE '^[A-Za-z].*\([^)]*=[^)]*\)[[:space:]]*\{' <<<"$CODE" || true)"
  if [[ -z "$DEFAULTS" ]]; then ok "keine Methode mit Default-Parameter"
  else nok "keine Methode mit Default-Parameter" "$DEFAULTS"; fi

  # 7) Injection-Disziplin (C-2): jeder sh-Script-String ist einfach gequotet.
  #    Die alte Pruefung verlangte "sh" und ein doppeltes Quote in DERSELBEN
  #    Zeile. Eine mehrzeilige Aufrufform
  #      archive = sh(returnStdout: true,
  #                   script: "bash \"$CI_LIB_DIR/x.sh\" ${pkg}").trim()
  #    blieb dadurch unentdeckt gruen, obwohl script: hier ein doppelt
  #    gequoteter, interpolierter String ist - exakt die Command-Injection,
  #    gegen die die ganze Disziplin gebaut ist. Deshalb getrennt (und ohne
  #    Bindung an dieselbe Zeile) pruefen: "script:" gefolgt von einem
  #    doppelten Quote, und ein blanker "sh <ws> "...""-Aufruf.
  BAD_SCRIPT="$(grep -nE 'script:[[:space:]]*"' <<<"$CODE" || true)"
  BAD_BARE="$(grep -nE '(^|[^A-Za-z_])sh[[:space:]]+"' <<<"$CODE" || true)"
  if [[ -z "$BAD_SCRIPT" && -z "$BAD_BARE" ]]; then ok "alle sh-Script-Strings einfach gequotet"
  else nok "alle sh-Script-Strings einfach gequotet" "$BAD_SCRIPT
$BAD_BARE"; fi

  # ... und kein '${' in einem einfach gequoteten sh-Aufrufstring - nicht nur
  # in Strings, die mit 'bash' beginnen (das war eine Luecke: ein anderer
  # Skriptname waere durchgerutscht), sondern in JEDEM script:-Wert und jedem
  # blanken sh '...'-Aufruf.
  SCRIPT_SQ="$(grep -oE "script:[[:space:]]*'[^']*'" <<<"$CODE")"
  BARE_SH_SQ="$(grep -oE "(^|[^A-Za-z_])sh[[:space:]]+'[^']*'" <<<"$CODE")"
  INTERP="$(printf '%s\n%s\n' "$SCRIPT_SQ" "$BARE_SH_SQ" | grep -F '${' || true)"
  if [[ -z "$INTERP" ]]; then ok "kein \${ in sh-Aufrufstrings"
  else nok "kein \${ in sh-Aufrufstrings" "$INTERP"; fi

  # 8) meta(): Whitelist-Pruefung exakt im Rumpf von meta() (I-2) - nicht nur
  #    als Text irgendwo in der Datei. "if (false && !(field in [...]))"
  #    enthaelt denselben Text, waere aber eine abgeschaltete Pruefung und
  #    muss deshalb rot sein.
  META_BODY="$(step_body 'String meta(String archive, String field)')"
  assert_contains "meta() prueft field exakt gegen die Whitelist" "$META_BODY" \
    "if (!(field in ['name', 'version'])) {"

  # 9) Klammern ausgeglichen (Kommentare ausgenommen)
  OPEN="$(tr -cd '{' <<<"$CODE" | wc -c | tr -d ' ')"; CLOSE="$(tr -cd '}' <<<"$CODE" | wc -c | tr -d ' ')"
  assert_eq "geschweifte Klammern ausgeglichen (Kommentare ausgenommen)" "$OPEN" "$CLOSE"

  # 10) call() (C-1): der Rumpf der Vollpipeline war von keinem der obigen
  #     Tests geschuetzt - "Methode existiert" (Test 5) prueft nur die
  #     Signaturzeile. call() delegiert den kompletten Ablauf jetzt an EINE
  #     Stage, die build() ruft - Struktur, Parameter und der post-Block
  #     werden hier gepinnt; der eigentliche Ablauf (Basis/Pakete, parallel,
  #     publish, finally) steckt jetzt in build() und wird dort (10b) gepinnt.
  CALL_BODY="$(step_body 'def call(Closure body)')"
  for NEEDLE in "booleanParam(name: 'BUILD_ALL'" \
                "booleanParam(name: 'SKIP_UPLOAD'" \
                "stage('Build')" \
                "archiveArtifacts artifacts: 'dist/*.tar.gz'" \
                "post {" \
                "cleanup {" \
                "script { this.cleanup() }" \
                "this.build(nexusUrl: cfg.nexusUrl, hostedRepo: cfg.hostedRepo," \
                "packages: cfg.packages" \
                "archive: false" \
                "cleanup: false"; do
    assert_contains "call(): enthaelt [$NEEDLE]" "$CALL_BODY" "$NEEDLE"
  done
  if ! grep -qF "stage('Pack & Publish')" <<<"$CALL_BODY"; then
    ok "call() hat keine eigene Pack-&-Publish-Stage mehr"
  else nok "call() hat keine eigene Pack-&-Publish-Stage mehr" "stage('Pack & Publish') noch vorhanden"; fi

  # call() enthaelt jetzt genau eine stage() auf Stages-Ebene (frueher zwei:
  # Setup + Pack & Publish, per Tiefenvergleich gepinnt - der Vergleich ergibt
  # mit nur noch einer Stage keinen Sinn mehr). build() baut seine eigene
  # stage(pkg) je Paket (10b).
  CALL_STAGE_COUNT="$(grep -oE 'stage\(' <<<"$CALL_BODY" | wc -l | tr -d ' ')"
  assert_eq "call() enthaelt genau eine stage()" "1" "$CALL_STAGE_COUNT"

  # 10b) build(Map) (Task 2): der Composite-Step fuer bestehende Pipelines -
  #      kein pipeline{}-Block, Schluessel-Whitelist gegen unbekannte
  #      Argumente, und der Ablauf, der frueher in call()/"Pack & Publish"
  #      stand (jetzt hier: Basis/Pakete ermitteln, parallel je Paket bauen/
  #      lesen/publishen, im finally archivieren und aufraeumen).
  if grep -qF 'Map build(Map args)' <<<"$CODE"; then ok "Methode vorhanden: Map build(Map args)"
  else nok "Methode vorhanden: Map build(Map args)" "nicht gefunden"; fi
  BUILD_MAP_BODY="$(step_body 'Map build(Map args)')"
  if [[ -n "$BUILD_MAP_BODY" ]] && ! grep -qE 'pipeline[[:space:]]*\{' <<<"$BUILD_MAP_BODY"; then
    ok "build() enthaelt keinen pipeline{}-Block"
  else nok "build() enthaelt keinen pipeline{}-Block" "Rumpf leer oder pipeline{} gefunden"; fi
  assert_contains "build() kennt die erlaubten Schluessel" "$BUILD_MAP_BODY" \
    "['nexusUrl', 'hostedRepo', 'credentialsId', 'packages', 'buildAll', 'skipUpload', 'base', 'archive', 'cleanup']"
  assert_contains "build() lehnt unbekannte Schluessel ab" "$BUILD_MAP_BODY" 'unbekannte Argumente'
  for NEEDLE in "stage(pkg)" \
                "if (skipUpload) {" \
                'echo "Basis   :' \
                'echo "Pakete  :' \
                "parallel pkgs.collectEntries" \
                "versions.sort()" \
                "currentBuild.description" \
                "install()" \
                "changedPackages(base, args.packages" \
                "buildSdist(pkg)" \
                "meta(archive, 'version')" \
                "meta(archive, 'name')" \
                "publish(archive: archive" \
                "finally" \
                "archiveArtifacts" \
                "cleanup()" \
                'echo "SKIP_UPLOAD/skipUpload gesetzt' \
                "if (unknown) {" \
                "if (!(k in allowed)) { unknown << k }" \
                "if (!args.nexusUrl) {" \
                "if (doArchive) {" \
                "if (doCleanup) {" \
                "boolean doArchive  = args.containsKey('archive')    ? toBool(args.archive, true)     : true" \
                "boolean doCleanup  = args.containsKey('cleanup')    ? toBool(args.cleanup, true)     : true" \
                "boolean buildAll   = args.containsKey('buildAll')   ? toBool(args.buildAll, false)   : paramOr('BUILD_ALL', false)" \
                "boolean skipUpload = args.containsKey('skipUpload') ? toBool(args.skipUpload, false) : paramOr('SKIP_UPLOAD', false)" \
                "String hostedRepo    = args.hostedRepo    ?: 'pypi-hosted'" \
                "String credentialsId = args.credentialsId ?: 'nexus-pypi-deploy'" \
                "nexusUrl: args.nexusUrl" \
                "archiveArtifacts artifacts: 'dist/*.tar.gz', allowEmptyArchive: true, fingerprint: true" \
                "catch (InterruptedException abort)" \
                "throw abort" \
                "catch (Exception e)"; do
    assert_contains "build(): enthaelt [$NEEDLE]" "$BUILD_MAP_BODY" "$NEEDLE"
  done

  # I-5: das Aufraeumen im finally (archivieren, cleanup()) steckt in einem
  # eigenen try/catch - eine Exception dort (z.B. rm -rf bei Agent-Verlust)
  # soll nicht die eigentliche Ursache aus dem try-Block verdecken.
  ARCHIVE_LINE="$(grep -n 'archiveArtifacts' <<<"$BUILD_MAP_BODY" | head -1 | cut -d: -f1)"
  CLEANUP_CALL_LINE="$(grep -n 'cleanup()' <<<"$BUILD_MAP_BODY" | tail -1 | cut -d: -f1)"
  if [[ -n "$ARCHIVE_LINE" && -n "$CLEANUP_CALL_LINE" && "$ARCHIVE_LINE" -lt "$CLEANUP_CALL_LINE" ]]; then
    ok "build(): archiveArtifacts steht im finally vor cleanup()"
  else nok "build(): archiveArtifacts steht im finally vor cleanup()" \
    "archiveArtifacts=Zeile [$ARCHIVE_LINE], cleanup()=Zeile [$CLEANUP_CALL_LINE]"; fi

  # Fix-Runde 2 / Befund 1: FlowInterruptedException (Abort/Timeout) erbt von
  # InterruptedException und damit von Exception - ohne einen spezifischen,
  # weiterwerfenden catch davor wuerde ein Abbruch waehrend Archivieren/
  # Aufraeumen von "catch (Exception e)" verschluckt statt propagiert. Pin:
  # der InterruptedException-Catch steht VOR dem allgemeinen Exception-Catch
  # und wirft weiter (throw abort).
  INTERRUPTED_CATCH_LINE="$(grep -n 'catch (InterruptedException abort)' <<<"$BUILD_MAP_BODY" | head -1 | cut -d: -f1)"
  GENERAL_CATCH_LINE="$(grep -n 'catch (Exception e)' <<<"$BUILD_MAP_BODY" | head -1 | cut -d: -f1)"
  if [[ -n "$INTERRUPTED_CATCH_LINE" && -n "$GENERAL_CATCH_LINE" && "$INTERRUPTED_CATCH_LINE" -lt "$GENERAL_CATCH_LINE" ]]; then
    ok "build(): catch (InterruptedException abort) steht vor catch (Exception e)"
  else nok "build(): catch (InterruptedException abort) steht vor catch (Exception e)" \
    "InterruptedException=Zeile [$INTERRUPTED_CATCH_LINE], Exception=Zeile [$GENERAL_CATCH_LINE]"; fi
  # "throw abort" selbst ist bereits ueber den NEEDLE-Loop oben (Zeile
  # "catch (InterruptedException abort)"/"throw abort") gegen BUILD_MAP_BODY
  # gepinnt - Gegenprobe (c) macht diesen Needle-Check rot, wenn "throw
  # abort" durch z.B. "echo 'abort'" ersetzt wird.

  # 10c) params-Zugriff abgesichert (paramOr()) - und I-2: der fruehere tote
  #      binding.hasVariable('params')-Zweig ist gestrichen (Script.getBinding()
  #      ist im Sandbox nicht freigegeben und zwang die Library ohne
  #      Funktionsgewinn zu einer trusted Installation). paramOr() besteht nur
  #      noch aus dem Property-Zugriff per try/catch; 'binding.' darf in der
  #      ganzen Datei nicht mehr vorkommen.
  if ! grep -qF 'binding.' <<<"$CODE"; then ok "kein 'binding.' mehr in der Datei (I-2)"
  else nok "kein 'binding.' mehr in der Datei (I-2)" "$(grep -nF 'binding.' <<<"$CODE")"; fi
  PARAMOR_BODY="$(step_body 'private boolean paramOr(String name, boolean dflt)')"
  assert_contains "paramOr(): Property-Zugriff per try { p = params }" "$PARAMOR_BODY" 'try { p = params }'

  # I-2: call() reicht buildAll/skipUpload jetzt explizit an build() durch -
  # damit faellt der reine Vollpipeline-Nutzer nie in paramOr() und ist von
  # dessen params-Zugriff unabhaengig.
  assert_contains "call(): reicht buildAll: params.BUILD_ALL durch (I-2)" "$CALL_BODY" "buildAll: params.BUILD_ALL"
  assert_contains "call(): reicht skipUpload: params.SKIP_UPLOAD durch (I-2)" "$CALL_BODY" "skipUpload: params.SKIP_UPLOAD"

  # I-1/I-2: 'false' as boolean waere true (Groovy-Truthiness) - toBool()
  # ersetzt alle 'as boolean'-Stellen. Kein 'as boolean' mehr in der Datei.
  if ! grep -qE 'as boolean' <<<"$CODE"; then ok "kein 'as boolean' mehr in der Datei (I-1/I-2)"
  else nok "kein 'as boolean' mehr in der Datei (I-1/I-2)" "$(grep -nE 'as boolean' <<<"$CODE")"; fi
  TOBOOL_BODY="$(step_body 'private boolean toBool(Object v, boolean dflt)')"
  assert_contains "toBool() parst Strings, statt Truthiness zu nutzen" "$TOBOOL_BODY" \
    "return v.toString().trim().equalsIgnoreCase('true')"

  # 11) Step-Vertrag (I-1): requireInstalled() und die Delegation von
  #     changedPackages(base) an changedPackages(base, packages) duerfen
  #     nicht unbemerkt aus einem Step verschwinden koennen.
  CP1_BODY="$(step_body 'List changedPackages(String base)')"
  CP2_BODY="$(step_body 'List changedPackages(String base, String packages)')"
  BUILD_BODY="$(step_body 'String buildSdist(String pkg)')"
  PUBLISH_BODY="$(step_body 'void publish(Map args)')"
  INSTALL_BODY="$(step_body 'String install()')"
  assert_contains "changedPackages(base, packages) prueft requireInstalled()" "$CP2_BODY" 'requireInstalled()'
  assert_contains "buildSdist() prueft requireInstalled()" "$BUILD_BODY" 'requireInstalled()'
  assert_contains "meta() prueft requireInstalled()" "$META_BODY" 'requireInstalled()'
  assert_contains "publish() prueft requireInstalled()" "$PUBLISH_BODY" 'requireInstalled()'
  assert_contains "changedPackages(base) delegiert an changedPackages(base, packages)" "$CP1_BODY" "changedPackages(base, '')"
  assert_contains "install() nutzt libDir()" "$INSTALL_BODY" 'libDir()'

  # I-4(a): Groovy<->Shell-Kopplung. Die ganze withEnv-Disziplin beruht
  # darauf, dass der Groovy-seitige withEnv-Schluessel und die im sh-String
  # referenzierte Shell-Variable denselben Namen tragen - das war bisher
  # ungeprueft. Je Aufrufstelle: jedes $NAME im sh-Script-String (ausser
  # CI_LIB_DIR, das kommt global aus env, nicht aus einem lokalen withEnv)
  # muss als Schluessel im umschliessenden withEnv([...]) auftauchen. Faengt
  # z.B. withEnv(["PKG=..."]) -> ["PACKAGE=..."] bei unveraendertem "$PKG" im
  # sh-String, oder dieselbe Umbenennung bei ARCHIVE/ARCH in meta().
  check_withenv_coupling() {  # <label> <rumpf>
    local label="$1" body="$2" refs keys missing r
    refs="$(grep -oE '\$[A-Z][A-Z0-9_]*' <<<"$body" | tr -d '$' | sort -u | grep -v '^CI_LIB_DIR$' || true)"
    keys="$(grep -oE '"[A-Z][A-Z0-9_]*=' <<<"$body" | sed -E 's/^"//; s/=$//' | sort -u)"
    missing=""
    for r in $refs; do
      grep -qxF "$r" <<<"$keys" || missing="$missing $r"
    done
    if [[ -z "$missing" ]]; then ok "$label: withEnv deckt alle \$NAME-Referenzen im sh-String ab (I-4a)"
    else nok "$label: withEnv deckt alle \$NAME-Referenzen im sh-String ab (I-4a)" \
      "fehlende withEnv-Keys fuer:$missing (vorhandene Keys: $keys)"; fi
  }
  check_withenv_coupling "changedPackages(base, packages)" "$CP2_BODY"
  check_withenv_coupling "buildSdist(pkg)" "$BUILD_BODY"
  check_withenv_coupling "meta(archive, field)" "$META_BODY"
  check_withenv_coupling "publish(args)" "$PUBLISH_BODY"
  unset -f check_withenv_coupling

  # I-4(a), Rest: zwei Mutationen, die eine reine Schluessel-Praesenzpruefung
  # nicht faengt, weil der withEnv-Schluessel gleich bleibt und nur der Wert
  # bzw. ein anderer String sich aendert - direkt als Volltext-Pin.
  #   withEnv(["FIELD=${field}"]) -> ["FIELD=name"]: FIELD bleibt Schluessel,
  #   "$FIELD" bleibt im sh-String stehen, aber FIELD wuerde dann immer den
  #   Namen statt des angeforderten Feldes tragen.
  assert_contains "meta(): FIELD kommt per Interpolation aus dem field-Parameter (I-4a)" \
    "$META_BODY" '"FIELD=${field}"'
  #   writeFile file: "${dir}/${n}" -> "${n}": schreibt dann ins Arbeits-
  #   verzeichnis statt nach .ci-lib/, ohne dass ein withEnv-Vergleich das
  #   sehen koennte (writeFile ist kein sh-Aufruf).
  assert_contains "install(): writeFile-Pfad enthaelt \${dir}/\${n} (I-4a)" \
    "$INSTALL_BODY" 'file: "${dir}/${n}"'

  # I-4(b): Secret-Scoping. Der Upload-sh-Schritt muss INNERHALB des
  # withCredentials-BLOCKS stehen (nicht nur textuell irgendwo dahinter) -
  # Kernaussage des README-Abschnitts "Umgang mit den Zugangsdaten". Eine
  # reine Zeilenreihenfolge-Pruefung (withCredentials-Zeile < sh-Zeile) reicht
  # NICHT: zieht man den sh-Schritt hinter den withCredentials-Block heraus
  # (M14), steht die withCredentials-Zeile immer noch textuell vor der
  # sh-Zeile, obwohl der sh-Schritt nicht mehr im Sichtbarkeitsbereich des
  # Secrets liegt - das war die urspruengliche Fassung dieses Tests (per
  # Gegenprobe hier selbst als Luecke gefunden). Deshalb: den Block explizit
  # per Klammertiefe herausschneiden (wie step_body(), aber der Rumpf hier
  # beginnt erst einige Zeilen NACH der Fundstelle - deshalb erst ab dem
  # ersten '{' zu zaehlen anfangen) und darin nach dem sh-Aufruf suchen.
  extract_block() {  # <text> <nadel>
    local text="$1" pat="$2"
    awk -v pat="$pat" '
      BEGIN { grab = 0; depth = 0; started = 0 }
      grab == 0 && index($0, pat) > 0 { grab = 1 }
      grab == 1 {
        print
        o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
        if (o > 0) started = 1
        depth += o - c
        if (started == 1 && depth <= 0) exit
      }
    ' <<<"$text"
  }
  WITHCRED_BLOCK="$(extract_block "$PUBLISH_BODY" 'withCredentials([usernamePassword(')"
  if [[ -n "$WITHCRED_BLOCK" ]] && grep -qF 'CI_LIB_DIR/publish-pypi.sh' <<<"$WITHCRED_BLOCK"; then
    ok "publish(): sh-Schritt liegt innerhalb von withCredentials (I-4b)"
  else nok "publish(): sh-Schritt liegt innerhalb von withCredentials (I-4b)" \
    "sh-Aufruf nicht im withCredentials-Block gefunden: $WITHCRED_BLOCK"; fi
  unset -f extract_block

  # I-4(c): Defaults ausserhalb von build(). publish() traegt seine eigenen
  # Defaults fuer hostedRepo/credentialsId - als Volltext gepinnt, damit ein
  # geaenderter Default (z.B. 'pypi-group' statt 'pypi-hosted', das waere ein
  # Group- statt Hosted-Repo) auffaellt. Und build() muss das eigene
  # credentialsId beim Aufruf von publish() durchreichen, statt es stillschweigend
  # fallen zu lassen.
  assert_contains "publish(): hostedRepo-Default ist 'pypi-hosted' (I-4c)" "$PUBLISH_BODY" \
    "\"NEXUS_PYPI_HOSTED=\${args.hostedRepo ?: 'pypi-hosted'}\""
  assert_contains "publish(): credentialsId-Default ist 'nexus-pypi-deploy' (I-4c)" "$PUBLISH_BODY" \
    "credentialsId: args.credentialsId ?: 'nexus-pypi-deploy'"
  assert_contains "build(): reicht credentialsId an publish() durch (I-4c)" "$BUILD_MAP_BODY" \
    "credentialsId: credentialsId"

  # M-6: cleanup() leert env.CI_LIB_DIR, damit ein spaeterer Einzel-Step in
  # derselben Pipeline an requireInstalled() scheitert (klare Fehlermeldung)
  # statt erst in der Shell an einem fehlenden Verzeichnis.
  CLEANUP_BODY="$(step_body 'void cleanup()')"
  assert_contains "cleanup() leert env.CI_LIB_DIR" "$CLEANUP_BODY" "env.CI_LIB_DIR = ''"

  # I-1: cleanup() darf in einer fremden Pipeline nicht deren eigenes dist/
  # wegreissen - nur die selbst erzeugten sdists entfernen, dist/ nur
  # wegraeumen, wenn es dadurch leer wird. 'rm -rf dist' darf im Rumpf nicht
  # mehr vorkommen.
  assert_contains "cleanup() entfernt nur die eigenen sdists (I-1)" "$CLEANUP_BODY" \
    "rm -f dist/*.tar.gz; rmdir dist 2>/dev/null || true"
  if ! grep -qF 'rm -rf dist' <<<"$CLEANUP_BODY"; then ok "cleanup(): kein 'rm -rf dist' mehr (I-1)"
  else nok "cleanup(): kein 'rm -rf dist' mehr (I-1)" "$(grep -n 'rm -rf dist' <<<"$CLEANUP_BODY")"; fi

  # 12) GDK-Iteratoren (I-3): .each/.collect/.findAll/.collectEntries duerfen
  #     nur an den zwei bekannten, unproblematischen Stellen stehen - jede
  #     weitere ist ein Rueckbau der for-Schleifen-Disziplin, unbemerkt durch
  #     die anderen Tests, die auf sh-Aufrufstellen und Signaturen zielen.
  GDK_CALLS="$(grep -nE '\.(each|collect|findAll|collectEntries)[[:space:]]*\{' <<<"$CODE" || true)"
  # Erlaubt: "pkgs.collectEntries { pkg ->" - der GDK-Iterator, den 'parallel'
  # als Map von Branch-Namen auf Closures erwartet; eine for-Schleife baut
  # keine Map und kann hier nicht einspringen. Und
  # "versions.sort().collect { k, v -> v }" - reines Groovy auf einer bereits
  # im Speicher stehenden Map, ruft keinen einzigen Step auf und ist fuer
  # CPS/GDK unproblematisch, vom Grep-Muster mangels Kontext aber nicht von
  # einem echten Verstoss zu unterscheiden - deshalb hier bewusst mit-erlaubt.
  GDK_BAD="$(grep -vE "collectEntries \{ pkg ->|\.collect \{ k, v -> v \}" <<<"$GDK_CALLS" \
             | grep -v '^[[:space:]]*$' || true)"
  if [[ -z "$GDK_BAD" ]]; then ok "keine GDK-Iteratoren ausser den zwei erlaubten (I-3)"
  else nok "keine GDK-Iteratoren ausser den zwei erlaubten (I-3)" "$GDK_BAD"; fi

  unset -f step_body

  if command -v groovyc >/dev/null 2>&1; then
    if groovyc -d "$TMP/groovyc" "$GROOVY" 2>"$TMP/groovyc.err"; then ok "groovyc kompiliert"
    else nok "groovyc kompiliert" "$(head -3 "$TMP/groovyc.err")"; fi
  else
    skip "groovyc Syntaxpruefung" "groovyc nicht installiert"
  fi
else
  nok "vars/pyMonorepo.groovy vorhanden" "Datei fehlt"
fi
echo
echo "=== examples ==="
for EX in "${ROOT}/examples/Jenkinsfile.embedded" "${ROOT}/examples/Jenkinsfile.steps"; do
  if [[ -f "$EX" ]]; then
    ok "$(basename "$EX") vorhanden"
    if grep -qE "pipeline[[:space:]]*\{" "$EX"; then ok "$(basename "$EX") ist eine eigene pipeline{}"
    else nok "$(basename "$EX") ist eine eigene pipeline{}" "kein pipeline{} gefunden"; fi
    USED="$(grep -oE 'pyMonorepo\.[A-Za-z]+' "$EX" | sed 's/pyMonorepo\.//' | sort -u)"
    for M in $USED; do
      if grep -qE "^[A-Za-z<>, ]+ ${M}\(" "${ROOT}/vars/pyMonorepo.groovy"; then
        ok "$(basename "$EX") nutzt vorhandene Methode $M"
      else
        nok "$(basename "$EX") nutzt vorhandene Methode $M" "keine Definition '${M}(' in vars/pyMonorepo.groovy"
      fi
    done
  else
    nok "$(basename "$EX") vorhanden" "Datei fehlt"
  fi
done

echo
echo "=== publish-pypi.sh Upload (curl-Stub) ==="
CURL_BIN="$(make_curl_stub)"

# Ruft publish-pypi.sh mit dem Stub im PATH. Setzt STUB_DIR frisch, damit
# curl-args/curl-stdin je Fall nur den einen Aufruf enthalten.
# Nutzung: run_publish <unterordner> [zusaetzliche VAR=wert ...]
# Ergebnis in $PUB_OUT (stdout+stderr), $PUB_RC, $PUB_ARGS, $PUB_STDIN.
run_publish() {
  local sub="$1"; shift
  PUB_D="${TMP}/pub-${sub}"
  rm -rf "$PUB_D"; mkdir -p "$PUB_D"
  PUB_OUT="$(env "$@" PATH="${CURL_BIN}:${PATH}" STUB_DIR="$PUB_D" \
             SKIP_REPO_CHECK=1 \
             NEXUS_URL=https://nexus.example.com \
             NEXUS_PYPI_HOSTED=pypi-hosted \
             bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"
  PUB_RC=$?
  PUB_ARGS="$(cat "${PUB_D}/curl-args" 2>/dev/null || true)"
  PUB_STDIN="$(cat "${PUB_D}/curl-stdin" 2>/dev/null || true)"
}

run_publish ok NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=204
assert_rc "Upload 204 -> rc 0" 0 "$PUB_RC"
assert_contains "Upload 204 -> OK-Meldung" "$PUB_OUT" "OK:"
assert_contains "URL ist die Components-API" "$PUB_ARGS" \
  "https://nexus.example.com/service/rest/v1/components?repository=pypi-hosted"
assert_contains "Formularfeld pypi.asset zeigt aufs Archiv" "$PUB_ARGS" \
  "pypi.asset=@\"${ARCHIVE}\""
assert_contains "POST wird verwendet" "$PUB_ARGS" "POST"
# Q-2: der Stub druckt den HTTP-Status nur, wenn --write-out in argv steht -
# ohne diese Assertion bliebe ein versehentlich gestrichenes --write-out
# unbemerkt gruen (der *-Zweig sieht dann ein leeres $HTTP).
assert_contains "Status wird per --write-out geholt" "$PUB_ARGS" '%{http_code}'
# I-2: der Testkatalog der Spec versprach einen Fall "SKIP_REPO_CHECK=1
# ueberspringt den Repo-Typ-Check (nur ein curl-Aufruf)", den es bisher nicht
# gab. Jeder curl-Aufruf traegt genau ein '--config'-Argument (die Config kommt
# ueber stdin) - Vorkommen davon in curl-args zaehlen also Aufrufe, nicht nur
# irgendein Merkmal des Aufrufs.
assert_eq "SKIP_REPO_CHECK=1 -> genau ein curl-Aufruf" "1" \
  "$(grep -c '^--config$' <<<"$PUB_ARGS")"

run_publish created NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=201
assert_rc "Upload 201 -> rc 0" 0 "$PUB_RC"

run_publish dup NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=400 \
  STUB_BODY='{"message":"Repository does not allow updating assets"}'
assert_rc "400 + does not allow updating -> rc 2" 2 "$PUB_RC"
assert_contains "400 -> Meldung nennt Version-Bump" "$PUB_OUT" "Version im Paket erhoehen"

run_publish dup2 NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=400 \
  STUB_BODY='package alpha-1.0.tar.gz already exists'
assert_rc "400 + already exists -> rc 2" 2 "$PUB_RC"

run_publish bad400 NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=400 \
  STUB_BODY='Malformed component'
assert_rc "400 mit anderem Body -> rc 1" 1 "$PUB_RC"
assert_contains "400 mit anderem Body -> Body erscheint" "$PUB_OUT" "Malformed component"

run_publish auth NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=401
assert_rc "401 -> rc 1" 1 "$PUB_RC"
assert_contains "401 -> Meldung nennt Zugangsdaten" "$PUB_OUT" "Zugangsdaten"

# Q-6: 403 (fehlendes nx-repository-view-*-add-Recht) war bisher ungetestet -
# das Muster '401|403)' im Skript stand ungepinnt neben dem getesteten '401'.
run_publish forbidden NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=403
assert_rc "403 -> rc 1" 1 "$PUB_RC"
assert_contains "403 -> Meldung nennt Zugangsdaten" "$PUB_OUT" "Zugangsdaten"

run_publish notfound NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=404
assert_rc "404 -> rc 1" 1 "$PUB_RC"
# Q-4: NICHT auf "pypi-hosted" pruefen - das trifft schon die immer gedruckte
# "Upload -> https://.../components?repository=pypi-hosted"-Zeile (Z. 80),
# unabhaengig vom 404-Zweig. Ein Teilstring, den nur die 404-Meldung enthaelt.
assert_contains "404 -> Meldung nennt das Repository" "$PUB_OUT" "existiert nicht unter"

# Q-7: das alte Duplikat-Muster ('400|already exists|...') traf auch auf
# "400" IM DATEINAMEN zu (z. B. foo-1.400.tar.gz) und meldete faelschlich rc 2.
# Das aktuelle Muster prueft nur noch auf "already exists"/"does not allow
# updating" im Body - hier gepinnt, damit eine Rueckkehr zum alten Muster rot
# wird.
run_publish notdup NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=400 \
  STUB_BODY='Malformed component foo-1.400.tar.gz'
assert_rc "400 mit '.400.' im Dateinamen -> rc 1 (kein falscher Duplikat-Treffer)" 1 "$PUB_RC"

run_publish weird NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=500 STUB_BODY='Internal Server Error'
assert_rc "500 -> rc 1" 1 "$PUB_RC"
assert_contains "500 -> Status erscheint" "$PUB_OUT" "500"

# I-1: curl-Fehler duerfen curls rohen Exit-Code NICHT durchreichen - 2 und 3
# sind als "Version existiert" bzw. "falscher Repo-Typ" bereits vergeben, und
# curl benutzt dieselben Zahlen fuer voellig andere Fehler (z.B. 3 = URL
# malformed, 2 = Init fehlgeschlagen). Jeder curl-Fehler muss deshalb auf rc 1
# abgebildet werden; curls Zahl steht nur noch in der Meldung.
run_publish netz NEXUS_USER=u NEXUS_PASS=p STUB_CURL_RC=7
assert_rc "curl-Fehler -> rc 1" 1 "$PUB_RC"
assert_contains "curl-Fehler -> Meldung nennt curl" "$PUB_OUT" "curl"
assert_contains "curl-Fehler -> Meldung nennt curl-Exit-Code" "$PUB_OUT" "curl-Exit 7"

run_publish netz_rc3 NEXUS_USER=u NEXUS_PASS=p STUB_CURL_RC=3
assert_rc "curl-Exit 3 kollidiert nicht mit Skript-Exit 3 (falscher Repo-Typ) -> rc 1" 1 "$PUB_RC"
assert_contains "curl-Exit 3 -> Meldung nennt curl-Exit-Code" "$PUB_OUT" "curl-Exit 3"

run_publish netz_rc2 NEXUS_USER=u NEXUS_PASS=p STUB_CURL_RC=2
assert_rc "curl-Exit 2 kollidiert nicht mit Skript-Exit 2 (Version existiert) -> rc 1" 1 "$PUB_RC"
assert_contains "curl-Exit 2 -> Meldung nennt curl-Exit-Code" "$PUB_OUT" "curl-Exit 2"

# I-3: der Diagnosekanal, auf dem der Umbruch-Guard begruendet ist ('cat
# "$ERR_FILE" >&2' plus '--show-error' im Skript), hatte bisher keine
# Abdeckung - der Stub liefert jetzt echten Text auf stderr, und der muss beim
# Aufrufer ankommen.
run_publish netz_stderr NEXUS_USER=u NEXUS_PASS=p STUB_CURL_RC=35 \
  STUB_CURL_STDERR='curl: (35) SSL connect error: TLS-Handshake fehlgeschlagen'
assert_rc "curl-Fehler mit Diagnosetext -> rc 1" 1 "$PUB_RC"
assert_contains "curl-Fehler -> Diagnosetext (ERR_FILE) landet in der Ausgabe" "$PUB_OUT" \
  "TLS-Handshake fehlgeschlagen"
assert_contains "curl-Fehler -> --show-error steht in argv" "$PUB_ARGS" "--show-error"

# Die Kernzusage des Zugangsdaten-Abschnitts im README, erstmals maschinell
# geprueft: das Passwort steht in der curl-Config auf stdin, nicht in argv.
run_publish secret NEXUS_USER=deploy-user NEXUS_PASS=s3cr3t-nicht-in-argv STUB_HTTP=204
if grep -q 's3cr3t-nicht-in-argv' <<<"$PUB_ARGS"; then
  nok "Passwort steht NICHT in argv" "gefunden in curl-args"
else ok "Passwort steht NICHT in argv"; fi
assert_contains "Passwort steht in der curl-Config auf stdin" "$PUB_STDIN" "s3cr3t-nicht-in-argv"
assert_contains "Benutzername steht in der curl-Config" "$PUB_STDIN" "deploy-user"

# Sonderzeichen im Passwort: " und \ sind im curl-Config-Format Steuerzeichen.
run_publish escape NEXUS_USER=u 'NEXUS_PASS=pa"ss\wort' STUB_HTTP=204
assert_contains 'Passwort mit " wird escaped' "$PUB_STDIN" 'pa\"ss'
assert_contains 'Passwort mit \ wird escaped' "$PUB_STDIN" 'ss\\wort'

# Q-1: ein Zeilenumbruch in Nutzername/Passwort kann die curl-Config (ein Wert
# pro Zeile) nicht darstellen - curl brach frueher beim Parsen ab und zitierte
# die zweite Zeile woertlich im Fehlertext, der ins Build-Log ging. Muss VOR
# jedem curl-Aufruf abgefangen werden: das Fragment "geheimB" darf nirgends
# in der Ausgabe auftauchen.
run_publish newline NEXUS_USER=u $'NEXUS_PASS=geheimA\ngeheimB' STUB_HTTP=204
assert_rc "Passwort mit Zeilenumbruch -> rc 1" 1 "$PUB_RC"
assert_contains "Passwort mit Zeilenumbruch -> Meldung nennt Zeilenumbruch" "$PUB_OUT" "Zeilenumbruch"
if grep -q 'geheimB' <<<"$PUB_OUT"; then
  nok "Passwort mit Zeilenumbruch -> zweite Zeile NICHT in der Ausgabe" "'geheimB' gefunden"
else ok "Passwort mit Zeilenumbruch -> zweite Zeile NICHT in der Ausgabe"; fi

# Q-3: check_repo_type ist vollstaendig ungetestet, solange jeder run_publish-
# Aufruf SKIP_REPO_CHECK=1 setzt. run_publish_checked laesst den Repo-Typ-
# Check laufen (beide curl-Aufrufe landen im selben STUB_DIR).
run_publish_checked() {
  local sub="$1"; shift
  PUB_D="${TMP}/pubchecked-${sub}"
  rm -rf "$PUB_D"; mkdir -p "$PUB_D"
  PUB_OUT="$(env "$@" PATH="${CURL_BIN}:${PATH}" STUB_DIR="$PUB_D" \
             NEXUS_URL=https://nexus.example.com \
             NEXUS_PYPI_HOSTED=pypi-hosted \
             bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"
  PUB_RC=$?
  PUB_ARGS="$(cat "${PUB_D}/curl-args" 2>/dev/null || true)"
  PUB_STDIN="$(cat "${PUB_D}/curl-stdin" 2>/dev/null || true)"
}

run_publish_checked group NEXUS_USER=u NEXUS_PASS=p \
  STUB_REPOS_JSON='[{"name":"pypi-hosted","type":"group","format":"pypi"}]'
assert_rc "Repo-Check: GROUP -> rc 3" 3 "$PUB_RC"
assert_contains "Repo-Check: GROUP -> Meldung nennt GROUP" "$PUB_OUT" "GROUP"

run_publish_checked proxy NEXUS_USER=u NEXUS_PASS=p \
  STUB_REPOS_JSON='[{"name":"pypi-hosted","type":"proxy","format":"pypi"}]'
assert_rc "Repo-Check: PROXY -> rc 3" 3 "$PUB_RC"

run_publish_checked wrongformat NEXUS_USER=u NEXUS_PASS=p \
  STUB_REPOS_JSON='[{"name":"pypi-hosted","type":"hosted","format":"maven2"}]'
assert_rc "Repo-Check: hosted/maven2 -> rc 3" 3 "$PUB_RC"
assert_contains "Repo-Check: hosted/maven2 -> Meldung nennt das Format" "$PUB_OUT" "maven2"

run_publish_checked okpypi NEXUS_USER=u NEXUS_PASS=geheim-checked-nicht-in-argv STUB_HTTP=204 \
  STUB_REPOS_JSON='[{"name":"pypi-hosted","type":"hosted","format":"pypi"}]'
assert_rc "Repo-Check: hosted/pypi -> rc 0, Upload laeuft" 0 "$PUB_RC"
assert_contains "Repo-Check: hosted/pypi -> OK-Meldung (Upload lief)" "$PUB_OUT" "OK:"
# Gilt fuer BEIDE curl-Aufrufe (Repo-Check und Upload) - derselbe Gegentest wie
# beim reinen Upload, hier aber ueber den kompletten Pfad mit Repo-Check davor.
if grep -q 'geheim-checked-nicht-in-argv' <<<"$PUB_ARGS"; then
  nok "Repo-Check: Passwort steht NICHT in argv (beide Aufrufe)" "gefunden in curl-args"
else ok "Repo-Check: Passwort steht NICHT in argv (beide Aufrufe)"; fi
# I-2: Gegenstueck zum SKIP_REPO_CHECK=1-Fall oben (dort genau ein
# curl-Aufruf) - ohne die Variable laufen Repo-Typ-Check UND Upload, also
# zwei curl-Aufrufe (je ein '--config'-Argument).
assert_eq "ohne SKIP_REPO_CHECK -> genau zwei curl-Aufrufe" "2" \
  "$(grep -c '^--config$' <<<"$PUB_ARGS")"

# Q-8: ';' und ',' sind im -F-Wert von curl Trennzeichen - ein Archivpfad mit
# ',' fuehrte ohne Anfuehrungszeichen um den Dateinamen zu
# "curl: (26) Failed to open/read local data" und der irrefuehrenden Meldung
# "Nexus nicht erreichbar". Betrifft pyMonorepo.publish(archive:...) und den
# direkten Skriptaufruf, nicht buildSdist (das erzeugt nie ein ','-Archiv).
COMMA_DIR="${TMP}/comma-archiv"
mkdir -p "$COMMA_DIR"
COMMA_ARCHIVE="${COMMA_DIR}/pkg,mit-komma-1.0.tar.gz"
cp "$ARCHIVE" "$COMMA_ARCHIVE"
PUB_D="${TMP}/pub-comma"
rm -rf "$PUB_D"; mkdir -p "$PUB_D"
PUB_OUT="$(env NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=204 PATH="${CURL_BIN}:${PATH}" \
           STUB_DIR="$PUB_D" SKIP_REPO_CHECK=1 \
           NEXUS_URL=https://nexus.example.com \
           NEXUS_PYPI_HOSTED=pypi-hosted \
           bash "$SCRIPTS/publish-pypi.sh" "$COMMA_ARCHIVE" 2>&1)"
PUB_RC=$?
PUB_ARGS="$(cat "${PUB_D}/curl-args" 2>/dev/null || true)"
assert_rc "Archivpfad mit ',' -> rc 0" 0 "$PUB_RC"
assert_contains "Archivpfad mit ',' landet vollstaendig (in Anfuehrungszeichen) in argv" \
  "$PUB_ARGS" "pypi.asset=@\"${COMMA_ARCHIVE}\""

skip "publish-pypi.sh echter Netzwerk-Upload" "braucht ein erreichbares Nexus - bewusst nicht getestet"

echo
echo "=== Bilanz ==="
printf 'PASS %d  FAIL %d  SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
