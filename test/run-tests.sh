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

# Stub fuer python3: bedient genau die zwei Aufrufe, die build-sdist.sh
# absetzt ('-c import build' und '-m build --sdist --outdir <dir>'), und legt
# im outdir ein Archiv wie make_sdist ab. Name/Version kommen aus STUB_NAME/
# STUB_VERSION, damit der Test den Fall "Ordner != Paketname" abdeckt.
# STUB_BIG_PKGINFO=1 polstert die erzeugte PKG-INFO wie make_big_sdist auf
# > 64 KB auf - fuer den I-1-Test, der den kompletten build-sdist.sh-Pfad
# (nicht nur sdist-meta.sh direkt) mit einer grossen sdist durchlaufen laesst.
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
case "${1:-}" in
  -c) exit 0 ;;   # 'import build' -> tut so, als waere python-build installiert
  -m) [[ "${2:-}" == build && "${3:-}" == --sdist && "${4:-}" == --outdir && -n "${5:-}" ]] \
        || { echo "python3-stub: unerwartete Argumente: $*" >&2; exit 2; }
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

echo
echo "=== vars/pyMonorepo.groovy ==="
GROOVY="${ROOT}/vars/pyMonorepo.groovy"
if [[ -f "$GROOVY" ]]; then
  ok "vars/pyMonorepo.groovy vorhanden"

  # Die materializeScripts()-Namensliste gezielt extrahieren, nicht per
  # Mengenvergleich ueber die ganze Datei: sonst bleiben vier reale
  # Bruchstellen unentdeckt gruen (siehe die vier Gegenproben unten). Das
  # Regex deckt mehr als [a-z-] ab, damit ein spaeteres 'build2.sh' nicht
  # faelschlich als fremder Name durchfaellt.
  NAMES_LINE="$(grep -oE "List names = \[[^]]*\]" "$GROOVY")"
  NAMED="$(grep -oE "'[A-Za-z][A-Za-z0-9_.-]*\.sh'" <<<"$NAMES_LINE" | tr -d "'" | sort -u)"
  HAVE="$(cd "$SCRIPTS" && ls *.sh | sort -u)"
  assert_eq "materializeScripts()-Liste == vorhandene Skripte" "$HAVE" "$NAMED"

  # libraryResource() muss exakt auf den Ressourcen-Pfad zeigen, unter dem
  # Task 1-3 die Skripte abgelegt haben.
  assert_contains "libraryResource-Pfad ist de/firma/ci" "$(cat "$GROOVY")" \
    'libraryResource("de/firma/ci/${n}")'

  # Das Zielverzeichnis kommt seit der CPS-Default-Param-Korrektur explizit
  # vom Aufrufer (materializeScripts('.ci-lib')). Der fuehrende Punkt ist
  # tragend, siehe Kommentar in vars/pyMonorepo.groovy.
  CALLARG="$(grep -oE "materializeScripts\('[^']*'\)" "$GROOVY" | head -1 | sed -E "s/.*\('([^']*)'\).*/\1/")"
  assert_eq "materializeScripts()-Aufruf hat ein Zielverzeichnis mit fuehrendem Punkt" \
    "." "${CALLARG:0:1}"

  # Die Namensliste allein beweist nur, dass die richtigen Skripte
  # *irgendwo* auftauchen - nicht, dass jeder sh-Aufruf das richtige Skript
  # in seiner Rolle trifft. Deshalb zusaetzlich die tatsaechlichen
  # Aufrufstellen (bash "$CI_LIB_DIR/<name>.sh" ...) zaehlen und gegen die
  # erwartete Rollenverteilung pruefen.
  CALLS="$(grep -oE '\$CI_LIB_DIR/[A-Za-z][A-Za-z0-9_.-]*\.sh' "$GROOVY" | sed -E 's#.*/##' | sort)"
  CALL_COUNTS="$(printf '%s\n' "$CALLS" | uniq -c | awk '{printf "%s: %s\n", $2, $1}' | sort)"
  EXPECTED_COUNTS=$'build-sdist.sh: 1\nchanged-packages.sh: 1\npublish-pypi.sh: 1\nsdist-meta.sh: 2'
  assert_eq "sh-Aufrufstellen rufen die erwarteten Skripte in der erwarteten Anzahl auf" \
    "$EXPECTED_COUNTS" "$CALL_COUNTS"

  # Verschachtelungstiefe an zwei Ankerpunkten statt einer reinen
  # Klammerzahl: eine verschobene schliessende Klammer aendert die
  # Gesamtzahl nicht, wohl aber die Tiefe, auf der die zweite Stage relativ
  # zur ersten liegt. Kommentare werden vorher entfernt (// bis Zeilenende),
  # sonst macht ein erweitertes Beispiel im Kopfkommentar den Test rot, ohne
  # dass Code sich geaendert hat.
  DEPTHS="$(awk '
    { line = $0; sub(/\/\/.*/, "", line)
      if (line ~ /stage\(.Setup.\)/)         print "SETUP", depth
      if (line ~ /stage\(.Pack & Publish.\)/) print "PACK", depth
      o = gsub(/\{/, "{", line)
      c = gsub(/\}/, "}", line)
      depth += o - c
    }
    END { print "TOTAL", depth }
  ' "$GROOVY")"
  SETUP_DEPTH="$(awk '$1=="SETUP"{print $2}' <<<"$DEPTHS")"
  PACK_DEPTH="$(awk '$1=="PACK"{print $2}' <<<"$DEPTHS")"
  TOTAL_DEPTH="$(awk '$1=="TOTAL"{print $2}' <<<"$DEPTHS")"
  assert_eq "geschweifte Klammern insgesamt ausgeglichen (Kommentare ausgenommen)" "0" "$TOTAL_DEPTH"
  assert_eq "stage('Setup') und stage('Pack & Publish') auf gleicher Verschachtelungstiefe" \
    "$SETUP_DEPTH" "$PACK_DEPTH"

  if command -v groovyc >/dev/null 2>&1; then
    if groovyc -d "$TMP/groovyc" "$GROOVY" 2>"$TMP/groovyc.err"; then
      ok "groovyc kompiliert"
    else
      nok "groovyc kompiliert" "$(head -3 "$TMP/groovyc.err")"
    fi
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
