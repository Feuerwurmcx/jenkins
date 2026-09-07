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
#   STUB_REPOS_CURL_RC Exit-Code NUR des Repo-Typ-Check-Aufrufs (Default 0) -
#                    simuliert eine nicht erreichbare Repositories-REST-API
#                    unabhaengig vom Index-/Upload-Aufruf (I-A)
make_curl_stub() {  # -> Verzeichnis fuer PATH auf stdout
  local d="${TMP}/curl-stub-bin"
  mkdir -p "$d"
  cat > "${d}/curl" <<'STUB'
#!/usr/bin/env bash
# curl-Stub aus test/run-tests.sh (make_curl_stub).
set -u
: "${STUB_DIR:?STUB_DIR fehlt}"
printf '%s\n' "$@" >> "${STUB_DIR}/curl-args"
# Nur lesen, wenn tatsaechlich etwas ansteht: das echte Skript speist jeden
# Aufruf ueber 'cfg_credentials | curl ...' (eine Pipe), aber ein direkter
# Testaufruf ohne speisende Pipe wuerde 'cat' sonst am interaktiven stdin
# haengen lassen, statt die Suite rot zu machen.
if [[ ! -t 0 ]]; then
  cat >> "${STUB_DIR}/curl-stdin"
fi

# Drei Aufrufarten, unterschieden an der URL - seit der Vorabpruefung nutzen
# zwei von ihnen --output, das Flag taugt nicht mehr zur Unterscheidung.
out=""
prev=""
write_out=0
url=""
for a in "$@"; do
  if [[ "$prev" == "--output" ]]; then out="$a"; fi
  if [[ "$a" == "--write-out" ]]; then write_out=1; fi
  case "$a" in https://*|http://*) url="$a" ;; esac
  prev="$a"
done

# Reihenfolge ist wichtig (M-7): die Upload-Erkennung ('v1/components' mit
# '?repository=') steht VOR dem generischen '*/simple/*'-Muster. Sonst wuerde
# eine Upload-URL, deren NEXUS_PYPI_HOSTED zufaellig 'simple' enthaelt (z.B.
# 'a/simple/b'), faelschlich als Index-Abfrage erkannt - die Muster
# ueberlappen sich, weil der Repo-Name Teil der Query-String ist.
case "$url" in
  */service/rest/v1/repositories)
    printf '%s' "${STUB_REPOS_JSON:-[]}"
    exit "${STUB_REPOS_CURL_RC:-0}" ;;
  */service/rest/v1/components\?repository=*)
    ;;  # Upload - faellt durch zum Code unterhalb dieses case-Blocks
  */simple/*)
    # Default 404: Paket unbekannt -> alle Bestandstests laden weiterhin hoch.
    if [[ -n "$out" ]]; then printf '%s' "${STUB_INDEX_BODY:-}" > "$out"; fi
    if [[ "$write_out" == 1 ]]; then printf '%s' "${STUB_INDEX_HTTP:-404}"; fi
    exit "${STUB_INDEX_CURL_RC:-0}" ;;
esac

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

# Wie fixture_repo, aber fuer ein Repo, das SELBST ein Paket ist:
# pyproject.toml in der Wurzel, Quellcode unter src/. Bewusst ein eigenes
# Fixture - ein Monorepo-Fixture und ein Einzelpaket-Fixture schliessen
# einander aus.
fixture_single_repo() {  # -> Pfad auf stdout
  local d="${TMP}/repo-single"
  rm -rf "$d"; mkdir -p "$d"
  cp -R "${ROOT}/test/fixture-single/." "$d/"
  (
    cd "$d"
    git init -q -b main
    git config user.email test@example.com
    git config user.name Test
    git add -A
    git commit -q -m "fixture-single"
  ) >/dev/null
  printf '%s\n' "$d"
}

# Baut ein Wegwerf-Repo mit frei waehlbarem Wurzelinhalt, um die Abgrenzung
# zwischen echtem Paket und reiner Werkzeugkonfiguration zu pruefen.
#   make_root_repo <unterordner> <inhalt der pyproject.toml oder "">
# Legt zusaetzlich immer einen Ordner alpha/ MIT setup.py an, damit sichtbar
# wird, ob die Wurzelerkennung die Unterordner-Suche verdraengt oder nicht.
make_root_repo() {  # -> Pfad auf stdout
  local d="${TMP}/rootrepo-$1"; shift
  rm -rf "$d"; mkdir -p "$d/alpha"
  echo "from setuptools import setup" > "$d/alpha/setup.py"
  if [[ -n "${1:-}" ]]; then printf '%s\n' "$1" > "$d/pyproject.toml"; fi
  (
    cd "$d"
    git init -q -b main
    git config user.email test@example.com
    git config user.name Test
    git add -A
    git commit -q -m init
  ) >/dev/null
  printf '%s\n' "$d"
}

# Wie make_root_repo, aber der Wurzelinhalt geht in setup.cfg statt
# pyproject.toml - fuer die Inhaltspruefung von setup.cfg (I-1/I-2).
#   make_root_setupcfg_repo <unterordner> <inhalt der setup.cfg oder "">
make_root_setupcfg_repo() {  # -> Pfad auf stdout
  local d="${TMP}/rootrepo-$1"; shift
  rm -rf "$d"; mkdir -p "$d/alpha"
  echo "from setuptools import setup" > "$d/alpha/setup.py"
  if [[ -n "${1:-}" ]]; then printf '%s\n' "$1" > "$d/setup.cfg"; fi
  (
    cd "$d"
    git init -q -b main
    git config user.email test@example.com
    git config user.name Test
    git add -A
    git commit -q -m init
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

# Ein Repo, das selbst ein Paket ist: build-sdist.sh bekommt '.' statt eines
# Ordnernamens. Die Logzeile "Ordner '.'" waere missverstaendlich.
SREPO_B="$(fixture_single_repo)"
STUB_BIN_S="$(make_python_stub)"
OUT="$(cd "$SREPO_B" && PATH="${STUB_BIN_S}:${PATH}" STUB_NAME='einzelpaket' STUB_VERSION='1.0.0' \
       bash "$SCRIPTS/build-sdist.sh" . 2>"${TMP}/single-build.err")"; RC=$?
assert_rc "build-sdist.sh . -> rc 0" 0 "$RC"
assert_contains "build-sdist.sh . -> Archivpfad" "$OUT" "dist/"
assert_contains "build-sdist.sh . meldet 'Repo-Wurzel', nicht \"Ordner '.'\"" \
  "$(cat "${TMP}/single-build.err")" "Repo-Wurzel ->"
if grep -q "Ordner '\.'" "${TMP}/single-build.err"; then
  nok "build-sdist.sh . vermeidet \"Ordner '.'\"" "alte Formulierung noch da"
else ok "build-sdist.sh . vermeidet \"Ordner '.'\""; fi

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
  assert_contains "build(): Stage-Label fuer das Wurzelpaket" "$BUILD_MAP_BODY" "Wurzelpaket"
  for NEEDLE in "stage(pkg == '.' ? 'Wurzelpaket' : pkg)" \
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
# Exakte Zeile statt Substring: ein "POST" irgendwo im argv-Dump aller
# curl-Aufrufe dieses Laufs waere kein Beleg dafuer, dass der Upload wirklich
# per POST geht (grep -qx statt assert_contains).
if grep -qx 'POST' <<<"$PUB_ARGS"; then
  ok "POST wird verwendet"
else
  nok "POST wird verwendet" "keine eigene 'POST'-Zeile in curl-args gefunden"
fi
# Q-2: der Stub druckt den HTTP-Status nur, wenn --write-out in argv steht -
# ohne diese Assertion bliebe ein versehentlich gestrichenes --write-out
# unbemerkt gruen (der *-Zweig sieht dann ein leeres $HTTP).
# I-A: SKIP_REPO_CHECK=1 bestaetigt den Repo-Typ nie (REPO_TYPE_BESTAETIGT
# bleibt 0), also kehrt already_published seither sofort zurueck, OHNE den
# Index abzufragen - nur noch der Upload-Aufruf laeuft. Vor I-A waren das zwei
# Aufrufe (Index + Upload); das ist jetzt genau der Fall, den die zwei
# I-A-Tests weiter unten ("SKIP_REPO_CHECK=1 + waere-Treffer") gezielt
# pruefen.
assert_eq "Status wird per --write-out geholt (nur Upload-Aufruf, kein Index seit I-A)" "1" \
  "$(grep -c '^%{http_code}$' <<<"$PUB_ARGS")"
# I-2: der Testkatalog der Spec versprach einen Fall "SKIP_REPO_CHECK=1
# ueberspringt den Repo-Typ-Check", den es bisher nicht gab. Jeder curl-Aufruf
# traegt genau ein '--config'-Argument (die Config kommt ueber stdin) -
# Vorkommen davon in curl-args zaehlen also Aufrufe, nicht nur irgendein
# Merkmal des Aufrufs.
# Seit I-A nur noch EIN Aufruf: SKIP_REPO_CHECK=1 laesst weder den
# Repo-Typ-Check noch (mangels bestaetigtem Typ) die Index-Abfrage laufen -
# nur der Upload bleibt.
assert_eq "SKIP_REPO_CHECK=1 -> nur Upload (weder Repo-Check noch Index)" "1" \
  "$(grep -c '^--config$' <<<"$PUB_ARGS")"

run_publish created NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=201
assert_rc "Upload 201 -> rc 0" 0 "$PUB_RC"

run_publish dup NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=400 \
  STUB_BODY='{"message":"Repository does not allow updating assets"}'
assert_rc "400 + does not allow updating -> rc 0 (uebersprungen)" 0 "$PUB_RC"
assert_contains "400 + does not allow updating -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
# M-5: "SKIP:" allein ist identisch mit der SKIP-Meldung der Vorabpruefung -
# beide Pfade sind an dieser Zeichenkette nicht zu unterscheiden. Erst der
# Klammerzusatz belegt, dass wirklich der 400-Duplikat-Pfad gegriffen hat.
assert_contains "400 + does not allow updating -> Herkunft ist der 400-Pfad" \
  "$PUB_OUT" "(Nexus meldete HTTP 400)"

run_publish dup2 NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=400 \
  STUB_BODY='package alpha-1.0.tar.gz already exists'
assert_rc "400 + already exists -> rc 0 (uebersprungen)" 0 "$PUB_RC"
assert_contains "400 + already exists -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
assert_contains "400 + already exists -> Herkunft ist der 400-Pfad" \
  "$PUB_OUT" "(Nexus meldete HTTP 400)"

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
# "400" IM DATEINAMEN zu (z. B. foo-1.400.tar.gz) und meldete faelschlich rc 1.
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
# $IDX_ARCHIVE ueberschreibt (wie bei run_publish_index) das publizierte
# Archiv - noetig, seit die bisherigen run_publish_index-Faelle mit einem
# bestaetigten Repo-Typ hierher umgezogen sind (I-A).
run_publish_checked() {
  local sub="$1" archive="${IDX_ARCHIVE:-$ARCHIVE}"; shift
  PUB_D="${TMP}/pubchecked-${sub}"
  rm -rf "$PUB_D"; mkdir -p "$PUB_D"
  PUB_OUT="$(env "$@" PATH="${CURL_BIN}:${PATH}" STUB_DIR="$PUB_D" \
             NEXUS_URL=https://nexus.example.com \
             NEXUS_PYPI_HOSTED=pypi-hosted \
             bash "$SCRIPTS/publish-pypi.sh" "$archive" 2>&1)"
  PUB_RC=$?
  PUB_ARGS="$(cat "${PUB_D}/curl-args" 2>/dev/null || true)"
  PUB_STDIN="$(cat "${PUB_D}/curl-stdin" 2>/dev/null || true)"
  PUB_UPLOADS="$(grep -c 'service/rest/v1/components' <<<"$PUB_ARGS" || true)"
}

# Fuer die (jetzt haeufigen) Faelle mit bestaetigtem "hosted pypi"-Repo-Typ:
# eine Kurzform, die STUB_REPOS_JSON nicht an jeder Aufrufstelle wiederholt.
STUB_REPOS_JSON_HOSTED_PYPI='[{"name":"pypi-hosted","type":"hosted","format":"pypi"}]'

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
  STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI"
assert_rc "Repo-Check: hosted/pypi -> rc 0, Upload laeuft" 0 "$PUB_RC"
assert_contains "Repo-Check: hosted/pypi -> OK-Meldung (Upload lief)" "$PUB_OUT" "OK:"
# Gilt fuer ALLE DREI curl-Aufrufe (Repo-Check, Index und Upload) - derselbe
# Gegentest wie beim reinen Upload, hier aber ueber den kompletten Pfad mit
# Repo-Check und Vorabpruefung davor.
if grep -q 'geheim-checked-nicht-in-argv' <<<"$PUB_ARGS"; then
  nok "Repo-Check: Passwort steht NICHT in argv (alle drei Aufrufe)" "gefunden in curl-args"
else ok "Repo-Check: Passwort steht NICHT in argv (alle drei Aufrufe)"; fi
# I-2: Gegenstueck zum SKIP_REPO_CHECK=1-Fall oben (dort zwei curl-Aufrufe) -
# ohne die Variable laufen Repo-Typ-Check, Vorabpruefung UND Upload, also drei
# curl-Aufrufe (je ein '--config'-Argument).
assert_eq "ohne SKIP_REPO_CHECK -> Repo-Check, Index und Upload" "3" \
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

# Leerzeichen, Tabs und CR in NEXUS_URL/NEXUS_PYPI_HOSTED lehnt curl mit Exit 3
# ab ("Malformed input to a URL function") und nennt dabei nicht, welcher Wert
# schuld ist. Das Skript prueft deshalb vorab. Kein Stub noetig: der Abbruch
# passiert, bevor curl ueberhaupt aufgerufen wird.
#
# Achtung bei den Assertions: rc 1 allein beweist hier NICHTS - ohne den Guard
# scheitert curl mit Exit 3, und den bildet das Skript ebenfalls auf 1 ab. Was
# den Guard belegt, ist dass die Meldung die Variable nennt UND dass curl gar
# nicht erst lief (keine "curl scheiterte"-Zeile).
url_guard() {  # <NEXUS_URL> <NEXUS_PYPI_HOSTED>
  UG_OUT="$(NEXUS_URL="$1" NEXUS_PYPI_HOSTED="$2" NEXUS_USER=u NEXUS_PASS=p \
            SKIP_REPO_CHECK=1 bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"
  UG_RC=$?
}

# <name> <erwartete Variable im Text> - prueft rc, Variablennennung und dass
# curl nicht gelaufen ist.
assert_guard() {
  assert_rc "$1 -> rc 1" 1 "$UG_RC"
  assert_contains "$1 -> Meldung nennt $2" "$UG_OUT" "$2"
  if grep -q 'curl scheiterte' <<<"$UG_OUT"; then
    nok "$1 -> bricht VOR dem curl-Aufruf ab" "curl lief trotzdem"
  else ok "$1 -> bricht VOR dem curl-Aufruf ab"; fi
}

url_guard "$(printf 'https://nexus.example.com\r')" pypi-hosted
assert_guard "NEXUS_URL mit CR" "NEXUS_URL"

url_guard " https://nexus.example.com" pypi-hosted
assert_guard "NEXUS_URL mit fuehrendem Leerzeichen" "NEXUS_URL"

url_guard "https://nexus example.com" pypi-hosted
assert_guard "NEXUS_URL mit Leerzeichen im Host" "NEXUS_URL"
assert_contains "Meldung nennt den od-Befehl zum Nachsehen" "$UG_OUT" "od -c"

url_guard "https://nexus.example.com$(printf '\t')" pypi-hosted
assert_guard "NEXUS_URL mit Tabulator" "NEXUS_URL"

url_guard "https://nexus.example.com" "hosted pypi"
assert_guard "NEXUS_PYPI_HOSTED mit Leerzeichen" "NEXUS_PYPI_HOSTED"

# Der Wert selbst darf nicht im Klartext in der Meldung stehen - dieselbe Form
# fuer alle Variablen, damit spaeter niemand versehentlich ein Secret ausgibt.
url_guard "https://geheim-intern.example.com " pypi-hosted
if grep -q 'geheim-intern' <<<"$UG_OUT"; then
  nok "Guard gibt den Wert nicht aus" "Wert steht in der Meldung"
else ok "Guard gibt den Wert nicht aus"; fi

echo
echo "=== publish-pypi.sh Vorabpruefung (Simple-Index) ==="
# $ARCHIVE stammt aus make_sdist mit Name 'Mein.Tolles_Paket' - der
# normalisierte Name im Index-Pfad muss also 'mein-tolles-paket' sein.
ARCHIVE_BASE="$(basename "$ARCHIVE")"

# Nutzung: run_publish_index <unterordner> [VAR=wert ...]
# Ergebnis in $PUB_OUT, $PUB_RC, $PUB_ARGS, $PUB_UPLOADS (Zahl der
# Upload-Aufrufe - daran haengt der Nachweis, dass wirklich uebersprungen wird).
# $IDX_ARCHIVE ueberschreibt, welches Archiv publiziert wird (Default $ARCHIVE)
# - fuer Faelle, die einen anderen Paketnamen oder ein kaputtes Archiv
# brauchen, ohne den Helfer selbst umzubauen.
#
# I-A: SKIP_REPO_CHECK=1 setzt REPO_TYPE_BESTAETIGT nie, also kehrt
# already_published seit der Kopplung an einen bestaetigten Repo-Typ sofort
# zurueck, OHNE den Index ueberhaupt abzufragen. Dieser Helfer dient deshalb
# nur noch dem einen Testfall weiter unten, der genau das belegt - fuer alle
# Index-Parsing-Faelle (Treffer, Formatvarianten, Fehlerpfade) ist
# run_publish_checked mit bestaetigtem "hosted pypi" der richtige Helfer,
# weil dort die Vorabpruefung tatsaechlich laeuft.
run_publish_index() {
  local sub="$1" archive="${IDX_ARCHIVE:-$ARCHIVE}"; shift
  PUB_D="${TMP}/pubidx-${sub}"
  rm -rf "$PUB_D"; mkdir -p "$PUB_D"
  PUB_OUT="$(env "$@" PATH="${CURL_BIN}:${PATH}" STUB_DIR="$PUB_D" \
             SKIP_REPO_CHECK=1 \
             NEXUS_URL=https://nexus.example.com \
             NEXUS_PYPI_HOSTED=pypi-hosted \
             NEXUS_USER=u NEXUS_PASS=p \
             bash "$SCRIPTS/publish-pypi.sh" "$archive" 2>&1)"
  PUB_RC=$?
  PUB_ARGS="$(cat "${PUB_D}/curl-args" 2>/dev/null || true)"
  PUB_UPLOADS="$(grep -c 'service/rest/v1/components' <<<"$PUB_ARGS" || true)"
}

echo
echo "=== publish-pypi.sh Vorabpruefung: Kopplung an bestaetigten Repo-Typ (I-A) ==="
# Die gefaehrliche Richtung aus dem Review: zeigt NEXUS_PYPI_HOSTED auf ein
# Group-Repo UND ist die Repositories-REST-API nicht erreichbar, aggregiert
# der Simple-Index der Group seine Member (auch einen PyPI-Proxy) - ein
# Treffer dort sagt nichts darueber aus, ob die Datei im Ziel-Repo liegt. Die
# beiden Faelle unten haetten VOR I-A beide faelschlich uebersprungen; jetzt
# muessen sie normal hochladen.

# 1) Repo-Typ-Check nicht erreichbar (STUB_REPOS_CURL_RC simuliert den
# curl-Exit, den 'curl --fail' z.B. bei HTTP 403 liefert) UND der Index HAETTE
# einen Treffer -> kein Skip, Upload laeuft, Hinweis erscheint. Genau 2
# '--config'-Aufrufe (Repo-Check + Upload) belegen, dass der Index gar nicht
# erst abgefragt wird.
run_publish_checked unreachable NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=204 \
  STUB_REPOS_CURL_RC=22 \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">${ARCHIVE_BASE}</a>"
assert_rc "I-A: Repo-Typ nicht erreichbar + waere-Treffer -> rc 0" 0 "$PUB_RC"
if grep -q 'SKIP:' <<<"$PUB_OUT"; then
  nok "I-A: Repo-Typ nicht erreichbar + waere-Treffer -> KEIN Skip" "SKIP: in der Ausgabe gefunden"
else ok "I-A: Repo-Typ nicht erreichbar + waere-Treffer -> KEIN Skip"; fi
assert_contains "I-A: Repo-Typ nicht erreichbar -> OK-Meldung (Upload lief)" "$PUB_OUT" "OK:"
assert_eq "I-A: Repo-Typ nicht erreichbar -> genau ein Upload-Aufruf" "1" "$PUB_UPLOADS"
assert_contains "I-A: Repo-Typ nicht erreichbar -> Hinweis auf unbestaetigten Typ" \
  "$PUB_OUT" "Repo-Typ nicht bestaetigt"
assert_eq "I-A: Repo-Typ nicht erreichbar -> kein Index-Aufruf (nur Repo-Check + Upload)" \
  "2" "$(grep -c '^--config$' <<<"$PUB_ARGS")"

# 2) SKIP_REPO_CHECK=1 (der Repo-Typ-Check laeuft gar nicht erst) UND der
# Index HAETTE ebenfalls einen Treffer -> dieselbe Erwartung. run_publish_index
# setzt SKIP_REPO_CHECK=1 fest - vor I-A war das der Fall, der ueberspringen
# sollte; jetzt ist es der Fall, der es NICHT mehr darf.
run_publish_index skiprepocheck STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">${ARCHIVE_BASE}</a>"
assert_rc "I-A: SKIP_REPO_CHECK=1 + waere-Treffer -> rc 0" 0 "$PUB_RC"
if grep -q 'SKIP:' <<<"$PUB_OUT"; then
  nok "I-A: SKIP_REPO_CHECK=1 + waere-Treffer -> KEIN Skip" "SKIP: in der Ausgabe gefunden"
else ok "I-A: SKIP_REPO_CHECK=1 + waere-Treffer -> KEIN Skip"; fi
assert_eq "I-A: SKIP_REPO_CHECK=1 -> genau ein Upload-Aufruf" "1" "$PUB_UPLOADS"
assert_contains "I-A: SKIP_REPO_CHECK=1 -> Hinweis auf unbestaetigten Typ" \
  "$PUB_OUT" "Repo-Typ nicht bestaetigt"
assert_eq "I-A: SKIP_REPO_CHECK=1 -> kein Index-Aufruf (nur Upload)" \
  "1" "$(grep -c '^--config$' <<<"$PUB_ARGS")"

echo
echo "=== publish-pypi.sh Vorabpruefung (Simple-Index, bestaetigter Repo-Typ) ==="
# Alle Faelle unten laufen mit bestaetigtem "hosted pypi"-Repo-Typ - sonst
# wuerde already_published seit I-A gar nicht mehr bis zum Index-Aufruf
# kommen und diese Faelle wuerden nichts mehr pruefen (siehe Kommentar bei
# run_publish_index oben).

# Achtung: rc 0 allein beweist hier nichts - der erfolgreiche Upload liefert
# ebenfalls 0. Den Skip belegen die SKIP-Meldung UND $PUB_UPLOADS == 0.
run_publish_checked hit NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<html><body><a href=\"../../packages/x/1/${ARCHIVE_BASE}#sha256=abc\">${ARCHIVE_BASE}</a></body></html>"
assert_rc "Index-Treffer -> rc 0" 0 "$PUB_RC"
assert_contains "Index-Treffer -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
assert_eq "Index-Treffer -> kein Upload-Aufruf" "0" "$PUB_UPLOADS"
# M-2: die volle URL pruefen, nicht nur den Schwanz - sonst bliebe grün, wenn
# '/repository/${NEXUS_PYPI_HOSTED}/' aus dem URL-Aufbau verschwaende (die
# Abfrage liefe dann gegen einen falschen Pfad, faende aber zufaellig noch
# 'simple/mein-tolles-paket/' irgendwo in argv).
assert_contains "Index-URL nutzt den PEP-503-Namen" "$PUB_ARGS" \
  "https://nexus.example.com/repository/pypi-hosted/simple/mein-tolles-paket/"
# I-B: die Index-Abfrage ist eine Abkuerzung, die den Build nicht aufhalten
# darf - beide Zeitgrenzen muessen in argv stehen, und zwar genau einmal (nur
# beim Index-Aufruf, nicht bei Repo-Check oder Upload).
assert_eq "I-B: Index-Abfrage hat --connect-timeout" "1" \
  "$(grep -c '^--connect-timeout$' <<<"$PUB_ARGS")"
assert_eq "I-B: Index-Abfrage hat --max-time" "1" \
  "$(grep -c '^--max-time$' <<<"$PUB_ARGS")"

# I-1: der Treffer steht als ERSTER Eintrag im Index, danach folgen weit mehr
# als 1000 weitere Eintraege - gebaut nach demselben Muster wie
# make_big_sdist() fuer den verwandten tar/sed-Fall. Das baut den Index gross
# genug auf, um den SIGPIPE-Abbruch unter 'pipefail' zu reproduzieren: wenn
# 'sed ... | grep -qxF ...' noch als Pipe stuende, wuerde grep beim (ersten)
# Treffer aussteigen und die Pipe schliessen, waehrend sed noch Hunderte
# Fuellzeilen nachschieben will - sed stirbt dann an SIGPIPE (rc 141), und
# 'pipefail' macht daraus den Pipeline-Status, obwohl grep selbst 0
# geliefert hatte. already_published wuerde faelschlich "nicht gefunden"
# melden und der Upload liefe trotz vorhandener Datei.
make_big_index_body() {  # <treffer-linktext> -> HTML auf stdout
  local hit="$1" i=0
  printf '<a href="x">%s</a>' "$hit"
  while [[ $i -lt 1200 ]]; do
    printf '<a href="x">anderes-fuellpaket-%d.tar.gz</a>' "$i"
    i=$((i+1))
  done
}
run_publish_checked bigidx NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="$(make_big_index_body "$ARCHIVE_BASE")"
assert_eq "I-1: Treffer vorne + >1000 Fuellzeilen -> kein Upload-Aufruf (Skip trotz grossem Index)" \
  "0" "$PUB_UPLOADS"
assert_contains "I-1: grosser Index -> SKIP-Meldung" "$PUB_OUT" "SKIP:"

run_publish_checked miss NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">ein-anderes-1.0.tar.gz</a>"
assert_rc "Index ohne Treffer -> rc 0" 0 "$PUB_RC"
assert_contains "Index ohne Treffer -> OK-Meldung" "$PUB_OUT" "OK:"
assert_eq "Index ohne Treffer -> genau ein Upload-Aufruf" "1" "$PUB_UPLOADS"

# Exakter Vergleich statt Substring: '<datei>' darf nicht in '<datei>.asc'
# gefunden werden.
run_publish_checked asc NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">${ARCHIVE_BASE}.asc</a>"
assert_eq "nur .asc gelistet -> kein Skip" "1" "$PUB_UPLOADS"
assert_contains "nur .asc gelistet -> OK-Meldung" "$PUB_OUT" "OK:"

# M-4: dass exakt/fixed-string verglichen wird (grep -qxF), nicht als Regex
# (grep -qxE). Als Regex waere '.' ein Platzhalter fuer ein beliebiges
# Zeichen - der gelistete Eintrag unterscheidet sich vom gesuchten Namen nur
# an einer Metazeichen-Position ('X' statt '.'). Mit -F darf das NICHT
# treffen; mit -E wuerde es (faelschlich) treffen.
run_publish_checked metachar NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">${ARCHIVE_BASE/./X}</a>"
assert_eq "M-4: nur an Metazeichen-Position abweichender Eintrag -> kein Skip" \
  "1" "$PUB_UPLOADS"
assert_contains "M-4: Metazeichen-Position -> OK-Meldung" "$PUB_OUT" "OK:"

# M-3: PEP-503-Normalisierung fasst WIEDERHOLTE Trennzeichen zu einem '-'
# zusammen. $ARCHIVE ('Mein.Tolles_Paket') hat keine doppelten Trennzeichen -
# ein zweites Archiv mit Name 'Foo_.Bar--Baz' deckt das ab: erwartet wird
# 'foo-bar-baz', nicht 'foo--bar--baz'.
ARCHIVE_DUPSEP="$(make_sdist idxdupsep 'Foo_.Bar--Baz' '1.0')"
IDX_ARCHIVE="$ARCHIVE_DUPSEP"
run_publish_checked dupsep NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">$(basename "$ARCHIVE_DUPSEP")</a>"
assert_contains "M-3: wiederholte Trennzeichen werden zu einem '-' zusammengefasst" \
  "$PUB_ARGS" "https://nexus.example.com/repository/pypi-hosted/simple/foo-bar-baz/"
unset IDX_ARCHIVE

# M-9: der Zweig "Paketname nicht lesbar" (sdist-meta.sh scheitert an einem
# kaputten Archiv) war bisher ungetestet. Muss wie jeder andere
# Vorabpruefungs-Fehler nur warnen, nicht abbrechen: Upload laeuft, rc 0.
ARCHIV_KAPUTT="${TMP}/kaputt.tar.gz"
printf 'kein echtes tar.gz-Archiv' > "$ARCHIV_KAPUTT"
IDX_ARCHIVE="$ARCHIV_KAPUTT"
run_publish_checked brokenname NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI"
assert_contains "M-9: Paketname nicht lesbar -> Hinweis" "$PUB_OUT" "Paketname nicht lesbar"
assert_eq "M-9: Paketname nicht lesbar -> Upload laeuft trotzdem" "1" "$PUB_UPLOADS"
assert_rc "M-9: Paketname nicht lesbar -> rc 0" 0 "$PUB_RC"
unset IDX_ARCHIVE

run_publish_checked notfound NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=404
assert_eq "Index 404 -> Upload laeuft" "1" "$PUB_UPLOADS"
assert_rc "Index 404 -> rc 0" 0 "$PUB_RC"

run_publish_checked unauth NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=401
assert_eq "Index 401 -> Upload laeuft trotzdem" "1" "$PUB_UPLOADS"
assert_contains "Index 401 -> Hinweis auf die uebersprungene Pruefung" "$PUB_OUT" "Vorabpruefung uebersprungen"
assert_rc "Index 401 -> rc 0" 0 "$PUB_RC"

run_publish_checked idxfail NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_CURL_RC=7
assert_eq "curl-Fehler beim Index -> Upload laeuft" "1" "$PUB_UPLOADS"
assert_contains "curl-Fehler beim Index -> Hinweis" "$PUB_OUT" "Vorabpruefung uebersprungen"

# Der 400-Pfad faengt ab, was die Vorabpruefung verpasst hat (Rennen zweier
# Builds, oder Index nicht abfragbar) - und ueberspringt jetzt ebenfalls.
run_publish_checked dup400 NEXUS_USER=u NEXUS_PASS=p STUB_REPOS_JSON="$STUB_REPOS_JSON_HOSTED_PYPI" \
  STUB_INDEX_HTTP=404 STUB_HTTP=400 \
  STUB_BODY='{"message":"Repository does not allow updating assets"}'
assert_rc "400 trotz Vorabpruefung -> rc 0" 0 "$PUB_RC"
assert_contains "400 trotz Vorabpruefung -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
assert_contains "400 trotz Vorabpruefung -> Herkunft ist der 400-Pfad" \
  "$PUB_OUT" "(Nexus meldete HTTP 400)"

skip "publish-pypi.sh echter Netzwerk-Upload" "braucht ein erreichbares Nexus - bewusst nicht getestet"

echo
echo "=== changed-packages.sh: Einzelpaket-Repos ==="
CP="bash $SCRIPTS/changed-packages.sh"

# Achtung: eine LEERE Ausgabe ist der heutige Zustand und beweist nichts.
# Jeder Einzelpaket-Fall prueft deshalb auf die exakte Ausgabe '.'.
SREPO="$(fixture_single_repo)"
assert_eq "Wurzel mit [project] -> ." "." \
  "$(cd "$SREPO" && $CP '' 2>/dev/null)"

# Eine Aenderung irgendwo im Repo zaehlt fuer das eine Paket - die Zuordnung
# ueber die erste Pfadkomponente gibt es hier nicht.
( cd "$SREPO" && echo "x" >> src/einzelpaket/__init__.py && git add -A && git commit -q -m aenderung )
assert_eq "Einzelpaket, Datei unter src/ geaendert -> ." "." \
  "$(cd "$SREPO" && $CP HEAD~1 2>/dev/null)"

# I-1: der eigentliche Fehlerfall - PACKAGES='.' mit echter Basis. Vorher lief
# '.' in der Schnittmenge gegen TOUCHED (erste Pfadkomponente) leer, weil '.'
# dort nie auftaucht - leise Ausgabe, rc 0, nichts gebaut.
assert_eq "I-1: PACKAGES='.' echte Basis, Datei geaendert -> ." "." \
  "$(cd "$SREPO" && PACKAGES='.' $CP HEAD~1 2>/dev/null)"

( cd "$SREPO" && git commit -q --allow-empty -m leer )
assert_eq "Einzelpaket, nichts geaendert -> leer" "" \
  "$(cd "$SREPO" && $CP HEAD~1 2>/dev/null)"

# setup.py in der Wurzel genuegt, ohne pyproject.toml.
RSETUP="$(make_root_repo setuppy "")"
( cd "$RSETUP" && echo "from setuptools import setup" > setup.py && git add -A && git commit -q -m setup )
assert_eq "Wurzel mit setup.py -> ." "." \
  "$(cd "$RSETUP" && $CP '' 2>/dev/null)"

# I-1/I-2: eine Wurzel-setup.cfg mit nur Linter-Konfiguration ist in
# Python-Monorepos verbreitet und darf kein Einzelpaket erzwingen.
RCFGFLAKE="$(make_root_setupcfg_repo cfgflake8 '[flake8]
max-line-length = 100')"
assert_eq "Wurzel-setup.cfg nur [flake8] -> weiter Monorepo" "alpha" \
  "$(cd "$RCFGFLAKE" && $CP '' 2>/dev/null)"

# Erst [metadata] bzw. [options] macht aus setup.cfg Paket-Metadaten.
RCFGMETA="$(make_root_setupcfg_repo cfgmeta '[metadata]
name = m')"
assert_eq "Wurzel-setup.cfg mit [metadata] -> ." "." \
  "$(cd "$RCFGMETA" && $CP '' 2>/dev/null)"

# Dieselbe Toleranz wie bei pyproject.toml: configparser erlaubt Leerraum um
# den Abschnittsnamen und einen Kommentar dahinter, eine strengere Pruefung
# wuerde ein echtes Einzelpaket lautlos auf "kein Paket" fallen lassen.
RCFGSPACED="$(make_root_setupcfg_repo cfgspaced '[ metadata ]
name = s')"
assert_eq "Wurzel-setup.cfg mit [ metadata ] -> ." "." \
  "$(cd "$RCFGSPACED" && $CP '' 2>/dev/null)"

RCFGCOMMENT="$(make_root_setupcfg_repo cfgcomment '[metadata]  # Kommentar
name = c')"
assert_eq "Wurzel-setup.cfg mit [metadata]  # Kommentar -> ." "." \
  "$(cd "$RCFGCOMMENT" && $CP '' 2>/dev/null)"

# [options.extras_require] und [metadata.foo] zaehlen weiterhin NICHT: dort
# folgt auf den Abschnittsnamen kein "]", sondern ein ".".
RCFGEXTRAS="$(make_root_setupcfg_repo cfgextras '[options.extras_require]
dev = pytest')"
assert_eq "nur [options.extras_require] -> weiter Monorepo" "alpha" \
  "$(cd "$RCFGEXTRAS" && $CP '' 2>/dev/null)"

RCFGMETAFOO="$(make_root_setupcfg_repo cfgmetafoo '[metadata.foo]
bar = baz')"
assert_eq "nur [metadata.foo] -> weiter Monorepo" "alpha" \
  "$(cd "$RCFGMETAFOO" && $CP '' 2>/dev/null)"

RPOETRY="$(make_root_repo poetry '[tool.poetry]
name = "p"
version = "1.0"')"
assert_eq "Wurzel mit [tool.poetry] -> ." "." \
  "$(cd "$RPOETRY" && $CP '' 2>/dev/null)"

# Der wichtigste Abgrenzungsfall: reine Werkzeugkonfiguration in der Wurzel
# darf ein Monorepo NICHT in ein Einzelpaket verwandeln.
RTOOL="$(make_root_repo toolonly '[tool.black]
line-length = 100')"
assert_eq "Wurzel nur mit [tool.black] -> weiter Monorepo" "alpha" \
  "$(cd "$RTOOL" && $CP '' 2>/dev/null)"

ROPT="$(make_root_repo optdeps '[project.optional-dependencies]
dev = ["pytest"]')"
assert_eq "nur [project.optional-dependencies] -> zaehlt nicht" "alpha" \
  "$(cd "$ROPT" && $CP '' 2>/dev/null)"

# Mi-1: das Muster darf gueltiges TOML nicht verwerfen - weder ein Kommentar
# hinter der Abschnittsklammer noch Leerraum innerhalb der Klammern.
RCOMMENT="$(make_root_repo comment '[project]  # Kommentar
name = "c"')"
assert_eq "Wurzel mit [project]  # Kommentar -> ." "." \
  "$(cd "$RCOMMENT" && $CP '' 2>/dev/null)"

RSPACED="$(make_root_repo spaced '[ project ]
name = "s"')"
assert_eq "Wurzel mit [ project ] -> ." "." \
  "$(cd "$RSPACED" && $CP '' 2>/dev/null)"

# Mischform: Wurzel-[project] UND ein Paketordner -> die Wurzel gewinnt.
RMIX="$(make_root_repo mixed '[project]
name = "m"
version = "1.0"')"
assert_eq "Mischform -> Wurzel gewinnt" "." \
  "$(cd "$RMIX" && $CP '' 2>/dev/null)"

# PACKAGES gewinnt auch gegen die Wurzelerkennung.
assert_eq "PACKAGES gewinnt gegen die Wurzelerkennung" "alpha" \
  "$(cd "$RMIX" && PACKAGES='alpha' $CP '' 2>/dev/null)"

# I-3: PACKAGES-Vorrang im Schnittmengen-Zweig (nicht in all_packages()) -
# braucht Wurzelpaket-Metadaten UND einen Paketordner UND eine brauchbare
# Basis, damit der Code ueberhaupt in den Schnittmengen-Zweig laeuft.
( cd "$RMIX" && echo "x" >> alpha/setup.py && git add -A && git commit -q -m "alpha-aenderung" )
assert_eq "Wurzelpaket + alpha/ geaendert, PACKAGES=alpha -> alpha" "alpha" \
  "$(cd "$RMIX" && PACKAGES='alpha' $CP HEAD~1 2>/dev/null)"

# I-1, Mischform-Fall: PACKAGES='. alpha' darf die Wurzel nicht verlieren -
# '.' zaehlt genau wie im Auto-Erkennungszweig jede geaenderte Datei, auch
# wenn nur alpha/ geaendert wurde.
assert_eq "I-1: Mischform, PACKAGES='. alpha' -> . und alpha" "$(printf '.\nalpha')" \
  "$(cd "$RMIX" && PACKAGES='. alpha' $CP HEAD~1 2>/dev/null)"

# I-3/M-7: root_is_package() nennt seinen Ausloeser auf stderr - ohne das war
# "Repo gilt als ein Paket" nur indirekt sichtbar (Pakete : ., Stage
# Wurzelpaket), nie der Grund. Muss GENAU EINMAL erscheinen und darf NICHT
# auf stdout landen (stdout ist die Paketliste, sie wird von
# 'sh(returnStdout: true)' gelesen).
HINT_ERR_TOML="$(cd "$SREPO" && $CP '' 2>&1 >/dev/null)"
assert_contains "I-3/M-7: Ausloeser pyproject.toml auf stderr" \
  "$HINT_ERR_TOML" "Paket-Metadaten in der Repo-Wurzel (pyproject.toml)"
assert_eq "I-3/M-7: Hinweis erscheint genau einmal" "1" \
  "$(grep -c 'Paket-Metadaten in der Repo-Wurzel' <<<"$HINT_ERR_TOML")"
assert_eq "I-3/M-7: stdout bleibt exakt '.' trotz Hinweis auf stderr" "." \
  "$(cd "$SREPO" && $CP '' 2>/dev/null)"

HINT_ERR_SETUPPY="$(cd "$RSETUP" && $CP '' 2>&1 >/dev/null)"
assert_contains "I-3/M-7: Ausloeser setup.py auf stderr" \
  "$HINT_ERR_SETUPPY" "Paket-Metadaten in der Repo-Wurzel (setup.py)"

HINT_ERR_CFG="$(cd "$RCFGMETA" && $CP '' 2>&1 >/dev/null)"
assert_contains "I-3/M-7: Ausloeser setup.cfg auf stderr" \
  "$HINT_ERR_CFG" "Paket-Metadaten in der Repo-Wurzel (setup.cfg)"

# M-1: die Verankerung (^...$) muss [project]/[metadata] mitten in einer
# Kommentar-/Textzeile verwerfen - fuer BEIDE Formate (Laborfall E).
RMIDTEXT="$(make_root_repo midtext '[tool.black]
# jedes Paket hat seinen eigenen [project]-Abschnitt
line-length = 100')"
assert_eq "M-1: [project] mitten im Kommentar -> weiter Monorepo" "alpha" \
  "$(cd "$RMIDTEXT" && $CP '' 2>/dev/null)"

RCFGMIDTEXT="$(make_root_setupcfg_repo cfgmidtext '[flake8]
max-line-length = 100
# das Wurzelpaket hat kein eigenes [metadata]')"
assert_eq "M-1: [metadata] mitten in einer Textzeile -> weiter Monorepo" "alpha" \
  "$(cd "$RCFGMIDTEXT" && $CP '' 2>/dev/null)"

# M-2: [options] allein (ohne [metadata]) macht aus setup.cfg Paket-Metadaten.
RCFGOPTIONS="$(make_root_setupcfg_repo cfgoptions '[options]
packages = find:')"
assert_eq "M-2: Wurzel-setup.cfg mit nur [options] -> ." "." \
  "$(cd "$RCFGOPTIONS" && $CP '' 2>/dev/null)"

# M-3: der Exit-Code des Einzelpaket-Zweigs (echte Basis) ist bisher
# ungeprueft - alle Assertions verglichen nur stdout.
OUT_M3="$(cd "$SREPO" && $CP HEAD~1 2>/dev/null)"; RC_M3=$?
assert_rc "M-3: Einzelpaket, echte Basis -> rc 0" 0 "$RC_M3"

# M-4: TOML ist case-sensitiv - [PROJECT] ist eine andere Tabelle als
# [project] und darf NICHT zaehlen.
RCASE="$(make_root_repo caseinsens '[PROJECT]
name = "x"')"
assert_eq "M-4: [PROJECT] (Grossschreibung) -> weiter Monorepo" "alpha" \
  "$(cd "$RCASE" && $CP '' 2>/dev/null)"

# Repo ganz ohne Paket: leere Ausgabe UND ein Hinweis - der stille Leerlauf
# war der eigentliche Fehler.
RNONE="${TMP}/rootrepo-none"; rm -rf "$RNONE"; mkdir -p "$RNONE/doku"
echo "nur doku" > "$RNONE/doku/index.md"
( cd "$RNONE" && git init -q -b main && git config user.email t@e.x && git config user.name T \
  && git add -A && git commit -q -m init ) >/dev/null
assert_eq "Repo ohne Paket -> leere Ausgabe" "" \
  "$(cd "$RNONE" && $CP '' 2>/dev/null)"
assert_contains "Repo ohne Paket -> Hinweis auf stderr" \
  "$(cd "$RNONE" && $CP '' 2>&1 >/dev/null)" "keine Paketordner"

# Mit PACKAGES hat der Aufrufer die Liste bewusst vorgegeben - kein Hinweis.
if grep -q 'keine Paketordner' <<<"$(cd "$RNONE" && PACKAGES='x' $CP '' 2>&1 >/dev/null)"; then
  nok "PACKAGES gesetzt -> kein Hinweis" "Hinweis erschien trotzdem"
else ok "PACKAGES gesetzt -> kein Hinweis"; fi

echo
echo "=== Bilanz ==="
printf 'PASS %d  FAIL %d  SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
