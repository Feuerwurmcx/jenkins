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

skip "publish-pypi.sh echter Upload" "braucht Netzwerk und ein Nexus - bewusst nicht getestet"

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

  # Kommentare raus, sonst zaehlen Beispiele im Kopfkommentar mit.
  CODE="$(sed -E 's#//.*$##' "$GROOVY")"

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

  # 10c) params-Zugriff abgesichert (paramOr()): binding.hasVariable('params')
  #      sieht 'params' in Jenkins-CPS nicht (GlobalVariable, kein Binding-
  #      Eintrag) - erst der Property-Zugriff (try { p = params }) loest sie
  #      ueber CpsScript.getProperty() auf. Beide Stufen im Rumpf gepinnt,
  #      nicht nur als Text irgendwo in der Datei (C-1).
  assert_contains "paramOr() sichert params per binding.hasVariable ab" "$CODE" "binding.hasVariable('params')"
  PARAMOR_BODY="$(step_body 'private boolean paramOr(String name, boolean dflt)')"
  assert_contains "paramOr(): binding.hasVariable('params') im Rumpf" "$PARAMOR_BODY" "binding.hasVariable('params')"
  assert_contains "paramOr(): Property-Zugriff als zweite Stufe (try { p = params })" "$PARAMOR_BODY" 'try { p = params }'

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

  # M-6: cleanup() leert env.CI_LIB_DIR, damit ein spaeterer Einzel-Step in
  # derselben Pipeline an requireInstalled() scheitert (klare Fehlermeldung)
  # statt erst in der Shell an einem fehlenden Verzeichnis.
  CLEANUP_BODY="$(step_body 'void cleanup()')"
  assert_contains "cleanup() leert env.CI_LIB_DIR" "$CLEANUP_BODY" "env.CI_LIB_DIR = ''"

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
echo "=== Bilanz ==="
printf 'PASS %d  FAIL %d  SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
