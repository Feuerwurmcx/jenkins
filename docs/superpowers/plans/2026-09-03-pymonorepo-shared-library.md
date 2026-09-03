# pyMonorepo Shared Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die vier Build-Skripte und die komplette Jenkins-Pipeline in eine Shared Library ueberfuehren, sodass ein Python-Monorepo nur noch einen konfigurierenden `Jenkinsfile` braucht und keinen `ci/`-Ordner mehr.

**Architecture:** Die Skripte liegen als `resources/de/firma/ci/*.sh` in der Library und werden zur Laufzeit per `libraryResource` + `writeFile` nach `.ci-lib` im Workspace auf den Agent geschrieben. `vars/pyMonorepo.groovy` enthaelt eine Declarative Pipeline, die per Config-Closure parametriert wird. Die Substanz bleibt in der Shell, weil die lokal testbar ist; Groovy bleibt duenne Orchestrierung.

**Tech Stack:** Jenkins Declarative Pipeline in einer Global Pipeline Library, Bash, git, Python (`build`/`setuptools`, `twine`) auf dem Agent.

## Global Constraints

- Zielstruktur, API und Stage-Aufbau exakt wie in `docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md`.
- Library-Name in Jenkins: `ci-shared`, referenziert mit Versions-Tag (`@v1.0.0`). Resource-Pfad: `de/firma/ci/`.
- Skripte werden immer als `bash <pfad>` aufgerufen, nie direkt — `writeFile` setzt kein Ausfuehrbar-Bit.
- Zielverzeichnis auf dem Agent: `.ci-lib` im Workspace. Der fuehrende Punkt ist tragend — er haelt den Ordner aus dem `*/`-Glob von `changed-packages.sh` heraus.
- Kommentare und Meldungen auf Deutsch, wie im Bestand. Bestehende Kommentare beim Verschieben nicht wegwerfen.
- Alle Shell-Skripte: `set -euo pipefail`, Fehlermeldungen nach stderr, Nutzdaten nach stdout.
- Kein Netzwerk in den Tests. Nicht abgedeckte Faelle als SKIP melden, nie stillschweigend uebergehen.
- `tar`-Aufrufe muessen mit GNU tar **und** BSD tar (macOS) funktionieren. `--wildcards` ist auf BSD nicht verfuegbar.
- Commits auf Deutsch, ohne Umlaute in der Betreffzeile, mit `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

| Datei | Verantwortung |
|---|---|
| `resources/de/firma/ci/changed-packages.sh` | Welche Top-Level-Pakete haben sich seit `<base>` geaendert |
| `resources/de/firma/ci/build-sdist.sh` | Ein Paketordner -> echte sdist in `dist/`, gibt den Pfad aus |
| `resources/de/firma/ci/sdist-meta.sh` | Name/Version aus der `PKG-INFO` einer sdist |
| `resources/de/firma/ci/publish-pypi.sh` | sdist per twine in ein Nexus-PyPI-hosted-Repo |
| `vars/pyMonorepo.groovy` | Config-Closure, Skript-Verteilung, Stages, Credentials, post |
| `examples/Jenkinsfile` | Vorlage fuer die Wurzel eines Monorepos |
| `test/run-tests.sh` | Testtreiber mit PASS/FAIL/SKIP-Bilanz |
| `test/fixture/` | Mini-Monorepo als Testdatenbasis |
| `.gitattributes` | `resources/**/*.sh text eol=lf` |
| `README-ci.md` | Einrichtung, Migration, Troubleshooting |

Geloescht: `pack.sh`, `upload-nexus.sh`, `version-of.sh` (RAW-Generation, vom `Jenkinsfile` nicht aufgerufen).

---

## Task 1: Repo-Struktur umbauen und tar portabel machen

Verschiebt die drei bestehenden Skripte in die Library-Struktur, loescht die RAW-Generation und macht die beiden `tar`-Aufrufe portabel. Ohne den tar-Fix ist in Task 2 nichts lokal testbar.

**Files:**
- Create: `.gitattributes`
- Move: `build-sdist.sh`, `sdist-meta.sh`, `publish-pypi.sh` -> `resources/de/firma/ci/`
- Move: `Jenkinsfile` -> `examples/Jenkinsfile`
- Delete: `pack.sh`, `upload-nexus.sh`, `version-of.sh`
- Modify: `resources/de/firma/ci/sdist-meta.sh`, `resources/de/firma/ci/build-sdist.sh`

**Interfaces:**
- Consumes: nichts (erste Task)
- Produces: `resources/de/firma/ci/{build-sdist,sdist-meta,publish-pypi}.sh` mit unveraenderten Aufrufsignaturen:
  - `bash build-sdist.sh <paket>` -> Archivpfad relativ zum cwd auf stdout, z.B. `dist/alpha-1.0.tar.gz`
  - `bash sdist-meta.sh <archiv> [name|version]` -> ein Wert auf stdout, default `version`
  - `bash publish-pypi.sh <archiv>` -> nichts auf stdout, Exit 2 bei bereits vorhandener Version, Exit 3 bei falschem Repo-Typ

- [ ] **Step 1: Verzeichnisse anlegen und Dateien verschieben**

```bash
cd /Users/bengoo/projects/jenkins
mkdir -p resources/de/firma/ci examples
git mv build-sdist.sh sdist-meta.sh publish-pypi.sh resources/de/firma/ci/
git mv Jenkinsfile examples/Jenkinsfile
git rm -q pack.sh upload-nexus.sh version-of.sh
```

- [ ] **Step 2: `.gitattributes` anlegen**

```bash
cat > .gitattributes <<'EOF'
# LF erzwingen: die Skripte werden per libraryResource auf den Agent
# geschrieben. CRLF im Shebang endet dort als
# "bad interpreter: /usr/bin/env bash^M".
resources/**/*.sh text eol=lf
test/**/*.sh      text eol=lf
EOF
```

- [ ] **Step 3: Den tar-Fehler reproduzieren**

Auf macOS (bsdtar) schlaegt der heutige Aufruf fehl:

```bash
cd "$(mktemp -d)" && mkdir -p pkg-1.0 \
  && printf 'Metadata-Version: 2.1\nName: foo\nVersion: 1.0\n' > pkg-1.0/PKG-INFO \
  && tar czf a.tar.gz pkg-1.0 \
  && tar xzOf a.tar.gz --wildcards '*/PKG-INFO'
```

Erwartet: `tar: Option --wildcards is not supported`. Auf einem GNU-tar-System liefert derselbe Aufruf die PKG-INFO — der Fix muss also auf beiden funktionieren.

- [ ] **Step 4: `sdist-meta.sh` portabel machen**

Ersetze in `resources/de/firma/ci/sdist-meta.sh` den Block ab `VALUE=` durch:

```bash
# Erst den exakten Member-Namen suchen, dann gezielt entpacken. Ein Glob im
# Extract-Aufruf ginge nicht portabel: GNU tar braucht dafuer --wildcards,
# BSD tar (macOS) kennt die Option nicht.
MEMBER="$(tar tzf "$ARCHIVE" | grep -m1 '/PKG-INFO$' || true)"
[[ -n "$MEMBER" ]] || { echo "FEHLER: kein PKG-INFO in $ARCHIVE" >&2; exit 1; }

VALUE="$(tar xzOf "$ARCHIVE" "$MEMBER" | sed -n "s/^${KEY}: //p" | head -1)"

[[ -n "$VALUE" ]] || { echo "FEHLER: ${KEY} nicht in PKG-INFO von $ARCHIVE" >&2; exit 1; }
echo "$VALUE"
```

- [ ] **Step 5: `build-sdist.sh` portabel machen**

Ersetze in `resources/de/firma/ci/build-sdist.sh` die Zeile mit `META=` (heute `tar xzOf "$ARCHIVE" --wildcards '*/PKG-INFO'`) durch:

```bash
# Siehe sdist-meta.sh: exakter Member statt Glob, wegen BSD tar.
PKGINFO_MEMBER="$(tar tzf "$ARCHIVE" | grep -m1 '/PKG-INFO$')"
META="$(tar xzOf "$ARCHIVE" "$PKGINFO_MEMBER" | head -40)"
```

Die Zeile darueber (`tar tzf "$ARCHIVE" | grep -q '/PKG-INFO$'`) bleibt unveraendert — `grep -q` auf der Member-Liste ist bereits portabel.

- [ ] **Step 6: Kopfkommentare auf den neuen Pfad ziehen**

In allen drei Skripten nennen die Aufrufbeispiele `ci/<skript>.sh`, ein Pfad, den es nach der Migration nicht mehr gibt. Ersetze ihn durch den blossen Skriptnamen:

```bash
cd /Users/bengoo/projects/jenkins
sed -i '' 's|ci/build-sdist\.sh|build-sdist.sh|g; s|ci/sdist-meta\.sh|sdist-meta.sh|g; s|ci/publish-pypi\.sh|publish-pypi.sh|g' resources/de/firma/ci/*.sh
grep -rn 'ci/' resources/de/firma/ci/ || echo "keine ci/-Referenz mehr"
```

- [ ] **Step 7: Syntax pruefen und den tar-Fix verifizieren**

```bash
cd /Users/bengoo/projects/jenkins
for f in resources/de/firma/ci/*.sh; do bash -n "$f" && echo "ok $f"; done

D="$(mktemp -d)" && mkdir -p "$D/foo-2.1" \
  && printf 'Metadata-Version: 2.1\nName: Mein.Tolles_Paket\nVersion: 2.1\n' > "$D/foo-2.1/PKG-INFO" \
  && (cd "$D" && tar czf a.tar.gz foo-2.1)
bash resources/de/firma/ci/sdist-meta.sh "$D/a.tar.gz" name
bash resources/de/firma/ci/sdist-meta.sh "$D/a.tar.gz" version
```

Erwartet: dreimal `ok`, dann `Mein.Tolles_Paket` und `2.1`. Vor dem Fix haette der `sdist-meta.sh`-Aufruf auf macOS `FEHLER: Name nicht in PKG-INFO` gemeldet.

- [ ] **Step 8: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add -A
git commit -m "$(cat <<'EOF'
Skripte in die Library-Struktur verschieben, tar portabel machen

build-sdist.sh, sdist-meta.sh und publish-pypi.sh liegen jetzt unter
resources/de/firma/ci/, der Jenkinsfile als Vorlage in examples/.
Die RAW-Generation (pack.sh, upload-nexus.sh, version-of.sh) wird nicht
mehr aufgerufen und faellt weg.

Die beiden tar-Aufrufe suchen den PKG-INFO-Member jetzt erst per tar tzf
und entpacken ihn dann namentlich. --wildcards ist GNU-spezifisch; BSD
tar lehnt die Option ab, womit die Skripte auf macOS nicht testbar waren.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Testtreiber und Tests fuer die bestehenden Skripte

Baut die Testinfrastruktur und deckt damit ab, was ohne Netzwerk pruefbar ist. Muss vor Task 3 stehen, weil `changed-packages.sh` dort per TDD entsteht und den Treiber schon braucht.

**Files:**
- Create: `test/run-tests.sh`
- Create: `test/fixture/alpha/setup.py`, `test/fixture/alpha/__init__.py`
- Create: `test/fixture/beta/pyproject.toml`
- Create: `test/fixture/gamma/README.md`
- Create: `test/fixture/docs/index.md`

**Interfaces:**
- Consumes: `resources/de/firma/ci/{build-sdist,sdist-meta,publish-pypi}.sh` aus Task 1
- Produces: `test/run-tests.sh` mit den Hilfsfunktionen, die Task 3 wiederverwendet:
  - `ok <name>`, `nok <name> [detail]`, `skip <name> <grund>`
  - `assert_eq <name> <erwartet> <ist>`
  - `assert_rc <name> <erwarteter_rc> <ist_rc>`
  - `assert_contains <name> <haystack> <needle>`
  - `make_sdist <unterordner> <name> <version>` -> gibt den Archivpfad aus
  - `fixture_repo` -> legt ein Git-Repo aus `test/fixture/` in `$TMP` an und gibt den Pfad aus
  - Globale Variablen: `$SCRIPTS` (Pfad zu `resources/de/firma/ci`), `$TMP` (aufgeraeumtes Temp-Verzeichnis)
  - Exit-Code: 0 wenn `FAIL == 0`, sonst 1. SKIP zaehlt nicht als Fehler.

- [ ] **Step 1: Fixture anlegen**

Das Fixture ist ein Mini-Monorepo: `alpha` und `beta` sind Pakete, `gamma` und `docs` sind es nicht.

```bash
cd /Users/bengoo/projects/jenkins
mkdir -p test/fixture/alpha test/fixture/beta test/fixture/gamma test/fixture/docs

cat > test/fixture/alpha/setup.py <<'EOF'
from setuptools import setup
setup(name="alpha", version="1.0.0", packages=[])
EOF
: > test/fixture/alpha/__init__.py

cat > test/fixture/beta/pyproject.toml <<'EOF'
[project]
name = "beta"
version = "0.2.0"
EOF

echo "kein Paket - weder pyproject.toml noch setup.py noch __init__.py" > test/fixture/gamma/README.md
echo "auch kein Paket" > test/fixture/docs/index.md
```

- [ ] **Step 2: Testtreiber schreiben**

```bash
cd /Users/bengoo/projects/jenkins
mkdir -p test
cat > test/run-tests.sh <<'DRIVER'
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
DRIVER
chmod +x test/run-tests.sh
```

- [ ] **Step 3: Testtreiber laufen lassen**

```bash
bash test/run-tests.sh; echo "Exit: $?"
```

Erwartet: alle `ok`, `FAIL 0`, Exit 0. Mindestens zwei SKIP auf dieser Maschine (build-sdist Happy Path mangels `setuptools`, echter Upload). Falls ein `sdist-meta`-Test fehlschlaegt, ist der tar-Fix aus Task 1 nicht korrekt uebernommen.

- [ ] **Step 4: Gegenprobe, dass der Treiber wirklich failt**

Ein Testtreiber, der nie rot wird, ist wertlos. Kurz brechen und zuruecknehmen:

```bash
cd /Users/bengoo/projects/jenkins
cp resources/de/firma/ci/sdist-meta.sh /tmp/sdist-meta.bak
sed -i '' "s/KEY='Name'/KEY='Nmae'/" resources/de/firma/ci/sdist-meta.sh
bash test/run-tests.sh; echo "Exit: $?"
cp /tmp/sdist-meta.bak resources/de/firma/ci/sdist-meta.sh && rm /tmp/sdist-meta.bak
bash test/run-tests.sh; echo "Exit: $?"
```

Erwartet: erster Lauf `FAIL` >= 1 und Exit 1, zweiter Lauf wieder `FAIL 0` und Exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add test
git commit -m "$(cat <<'EOF'
Testtreiber und Fixture fuer die Build-Skripte

Deckt ab, was ohne Netzwerk pruefbar ist: Syntax, sdist-meta gegen ein
handgebautes Archiv, die Guard-Clauses von build-sdist und publish-pypi.
Der Happy Path von build-sdist und der echte Upload werden als SKIP
gemeldet statt stillschweigend uebergangen.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: changed-packages.sh

Das Skript, das der bisherige `Jenkinsfile` aufruft, ohne dass es im Repo liegt. Entsteht per TDD: erst die Tests, dann das Skript.

**Files:**
- Create: `resources/de/firma/ci/changed-packages.sh`
- Modify: `test/run-tests.sh` (Testblock ergaenzen, vor dem `=== Bilanz ===`-Block)

**Interfaces:**
- Consumes: `fixture_repo`, `assert_eq`, `ok`, `nok`, `$SCRIPTS`, `$TMP` aus Task 2
- Produces: `bash changed-packages.sh <base>` — Paketnamen zeilenweise auf stdout, alphabetisch sortiert, Hinweise auf stderr, Exit 0 auch wenn nichts gefunden wurde. Liest `PACKAGES` aus der Umgebung. Wird von `vars/pyMonorepo.groovy` in Task 4 aufgerufen.

- [ ] **Step 1: Die failenden Tests schreiben**

Fuege in `test/run-tests.sh` direkt vor der Zeile `echo` + `echo "=== Bilanz ==="` ein:

```bash
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
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag bestaetigen**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh; echo "Exit: $?"
```

Erwartet: der `=== Syntax ===`-Block meldet nichts fuer `changed-packages.sh` (die Datei fehlt noch, das Glob findet sie nicht). Von den zehn neuen Assertions failen neun, weil `bash .../changed-packages.sh` mit "No such file or directory" und rc 127 abbricht. Exit 1.

Die eine Ausnahme ist `nur Nicht-Pakete geaendert`: sie erwartet leere Ausgabe und ist deshalb schon vor der Implementierung gruen. Das ist kein Fehler, aber auch kein Beweis — der Beweis fuer diesen Fall liegt darin, dass die Nachbartests danach nicht leer sind.

- [ ] **Step 3: Das Skript schreiben**

```bash
cd /Users/bengoo/projects/jenkins
cat > resources/de/firma/ci/changed-packages.sh <<'EOF'
#!/usr/bin/env bash
# Listet die Pakete, die sich seit <base> geaendert haben - eines pro Zeile.
#
#   changed-packages.sh <base>
#
# Ein Paket ist ein Top-Level-Ordner mit pyproject.toml, setup.py oder
# __init__.py. Statt der Auto-Erkennung eine feste Liste:
#
#   PACKAGES="paket1 paket2" changed-packages.sh <base>
#
# Ausgegeben wird die Schnittmenge aus "ist ein Paket" und "steckt im git diff
# seit <base>". Drei Faelle bauen bewusst alles: keine brauchbare Basis (erster
# Build, neuer Branch, gepruntete History) sowie Aenderungen an ci/ oder am
# Jenkinsfile - wer die CI aendert, will sie auf allem sehen.
#
# Nutzdaten gehen nach stdout, Hinweise nach stderr: der Aufrufer liest stdout
# als Paketliste.
set -euo pipefail
shopt -s nullglob

BASE="${1:-}"

all_packages() {
  if [[ -n "${PACKAGES:-}" ]]; then
    # Absichtlich ohne Quotes: PACKAGES ist eine durch Leerzeichen getrennte Liste.
    printf '%s\n' ${PACKAGES} | sort -u
    return
  fi
  local d
  for d in */; do
    d="${d%/}"
    if [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/__init__.py" ]]; then
      printf '%s\n' "$d"
    fi
  done | sort -u
}

usable_base() {
  [[ -n "$BASE" ]] || return 1
  git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1
}

if ! usable_base; then
  echo "HINWEIS: keine brauchbare Basis ('${BASE}') - baue alle Pakete" >&2
  all_packages
  exit 0
fi

CHANGED_FILES="$(git diff --name-only "$BASE" HEAD)"

if grep -qE '^(ci/|Jenkinsfile$)' <<<"$CHANGED_FILES"; then
  echo "HINWEIS: CI-Konfiguration geaendert - baue alle Pakete" >&2
  all_packages
  exit 0
fi

# Erste Pfadkomponente je geaenderter Datei = moeglicher Paketordner.
TOUCHED="$(cut -d/ -f1 <<<"$CHANGED_FILES" | sort -u)"

while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  if grep -qxF "$pkg" <<<"$TOUCHED"; then
    printf '%s\n' "$pkg"
  fi
done < <(all_packages)

exit 0
EOF
```

- [ ] **Step 4: Tests laufen lassen, jetzt gruen**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh; echo "Exit: $?"
```

Erwartet: `FAIL 0`, Exit 0, und der Syntax-Block enthaelt jetzt auch `ok bash -n changed-packages.sh`.

- [ ] **Step 5: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add resources/de/firma/ci/changed-packages.sh test/run-tests.sh
git commit -m "$(cat <<'EOF'
changed-packages.sh ergaenzen

Das Skript wurde vom Jenkinsfile aufgerufen, lag aber nicht im Repo.
Verhalten nach der bisherigen README-Beschreibung: Pakete sind
Top-Level-Ordner mit pyproject.toml, setup.py oder __init__.py, PACKAGES
ersetzt die Erkennung, und ohne brauchbare Basis oder bei Aenderungen an
der CI wird bewusst alles gebaut.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: vars/pyMonorepo.groovy

Die Pipeline. Lokal nicht ausfuehrbar — kein `groovy`/`groovyc` auf der Maschine, und ein Declarative-Block braucht ohnehin Jenkins. Die Verifikation ist deshalb strukturell, plus ein Testlauf auf einem echten Jenkins beim Rollout.

**Files:**
- Create: `vars/pyMonorepo.groovy`
- Modify: `test/run-tests.sh` (Strukturpruefung ergaenzen)

**Interfaces:**
- Consumes: alle vier Skripte aus `resources/de/firma/ci/` mit den in Task 1 und 3 festgelegten Signaturen
- Produces: den Step `pyMonorepo(Closure)` mit den Config-Schluesseln `nexusUrl` (Pflicht), `hostedRepo`, `credentialsId`, `packages`, `keepBuilds`

- [ ] **Step 1: Die Datei schreiben**

```bash
cd /Users/bengoo/projects/jenkins
mkdir -p vars
cat > vars/pyMonorepo.groovy <<'EOF'
// Standard-Pipeline fuer ein Python-Monorepo: geaenderte Pakete ermitteln, je
// eine sdist bauen und in ein Nexus-PyPI-hosted-Repo hochladen.
//
//   @Library('ci-shared@v1.0.0') _
//
//   pyMonorepo {
//       nexusUrl   = 'https://nexus.example.com'
//       hostedRepo = 'pypi-hosted'
//   }
//
// Die eigentliche Arbeit steckt in den Shell-Skripten unter
// resources/de/firma/ci/. Sie werden zur Laufzeit auf den Agent
// geschrieben - ein Monorepo braucht dadurch keinen ci/-Ordner mehr. Der
// Zuschnitt ist Absicht: was in .sh steckt, ist lokal testbar, was in Groovy
// steckt, erst auf einem Jenkins.

def call(Closure body) {
    Map cfg = [
        nexusUrl     : null,
        hostedRepo   : 'pypi-hosted',
        credentialsId: 'nexus-pypi-deploy',
        packages     : '',
        keepBuilds   : 30,
    ]
    body.resolveStrategy = Closure.DELEGATE_FIRST
    body.delegate = cfg
    body()

    if (!cfg.nexusUrl) {
        error 'pyMonorepo: nexusUrl fehlt - Basis-URL der Nexus-Instanz setzen'
    }

    pipeline {
        agent any

        options {
            timestamps()
            buildDiscarder(logRotator(numToKeepStr: "${cfg.keepBuilds}"))
            disableConcurrentBuilds()
        }

        parameters {
            booleanParam(name: 'BUILD_ALL', defaultValue: false,
                         description: 'Alle Pakete bauen statt nur der geänderten')
            booleanParam(name: 'SKIP_UPLOAD', defaultValue: false,
                         description: 'Nur bauen, kein Upload (Dry-Run)')
        }

        stages {

            stage('Setup') {
                steps {
                    script {
                        // Ueber env statt ueber eine lokale Variable: der Pfad wird in
                        // einer spaeteren Stage und im post-Block wieder gebraucht.
                        env.CI_LIB_DIR = materializeScripts()

                        // Basis fuer den Diff: letzter erfolgreicher Build (Git-Plugin
                        // setzt das), sonst HEAD~1, sonst leer -> alles bauen.
                        def base = params.BUILD_ALL ? '' :
                            (env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: sh(returnStdout: true, script:
                                'git rev-parse HEAD~1 2>/dev/null || true').trim())

                        def out
                        withEnv(["PACKAGES=${cfg.packages}"]) {
                            out = sh(returnStdout: true, script:
                                "bash ${env.CI_LIB_DIR}/changed-packages.sh '${base}'").trim()
                        }
                        env.CHANGED = out
                        def pkgs = out ? out.split('\n') as List : []

                        echo "Basis   : ${base ?: '(keine – alles)'}"
                        echo "Pakete  : ${pkgs.join(', ') ?: '(keine Änderungen)'}"

                        if (pkgs.isEmpty()) {
                            currentBuild.result = 'SUCCESS'
                            currentBuild.description = 'keine Paketänderungen'
                        } else {
                            currentBuild.description = "${pkgs.size()} Paket(e): ${pkgs.join(', ')}"
                        }
                    }
                }
            }

            stage('Pack & Publish') {
                when { expression { env.CHANGED?.trim() } }
                steps {
                    script {
                        def dir  = env.CI_LIB_DIR
                        def pkgs = env.CHANGED.trim().split('\n') as List
                        def versions = [:]   // CPS-Branches laufen kooperativ, kein Sync noetig

                        parallel pkgs.collectEntries { pkg ->
                            [ (pkg): {
                                stage(pkg) {
                                    // build-sdist.sh liefert den vom Build erzeugten
                                    // Dateinamen zurueck - der wird NICHT selbst
                                    // zusammengebaut, weil setuptools Name und Version
                                    // normalisiert.
                                    def archive = sh(returnStdout: true,
                                        script: "bash ${dir}/build-sdist.sh '${pkg}'").trim()
                                    // Aus PKG-INFO statt aus dem Dateinamen: Paketnamen
                                    // duerfen selbst Bindestriche enthalten.
                                    def version = sh(returnStdout: true,
                                        script: "bash ${dir}/sdist-meta.sh '${archive}' version").trim()
                                    def distName = sh(returnStdout: true,
                                        script: "bash ${dir}/sdist-meta.sh '${archive}' name").trim()
                                    echo "${pkg}: ${distName} ${version}"

                                    if (params.SKIP_UPLOAD) {
                                        echo "SKIP_UPLOAD gesetzt – ${archive} nicht hochgeladen"
                                    } else {
                                        // Nexus-Werte nur um den Upload herum, nicht global:
                                        // dieselbe Ueberlegung wie beim Secret unten.
                                        withEnv(["NEXUS_URL=${cfg.nexusUrl}",
                                                 "NEXUS_PYPI_HOSTED=${cfg.hostedRepo}"]) {
                                            // Secret nur fuer diesen einen sh-Schritt gebunden
                                            // und von Jenkins im Log maskiert. Es wird NICHT in
                                            // den Groovy-String interpoliert - das Skript liest
                                            // es selbst aus der Umgebung.
                                            withCredentials([usernamePassword(
                                                    credentialsId: cfg.credentialsId,
                                                    usernameVariable: 'NEXUS_USER',
                                                    passwordVariable: 'NEXUS_PASS')]) {
                                                sh "bash ${dir}/publish-pypi.sh '${archive}'"
                                            }
                                        }
                                    }
                                    versions[pkg] = "${distName} ${version}"
                                }
                            }]
                        }

                        currentBuild.description = versions.sort()
                            .collect { k, v -> v }.join(', ')
                    }
                }
            }
        }

        post {
            always {
                archiveArtifacts artifacts: 'dist/*.tar.gz',
                                 allowEmptyArchive: true, fingerprint: true
            }
            cleanup {
                sh 'rm -rf dist'
                script {
                    if (env.CI_LIB_DIR) {
                        sh "rm -rf '${env.CI_LIB_DIR}'"
                    }
                }
            }
        }
    }
}

// Schreibt die Skripte aus resources/ auf den Agent und gibt das Verzeichnis
// zurueck. libraryResource liefert nur den Dateiinhalt als String - resources/
// selbst liegt nie auf dem Agent.
//
// Das Ziel liegt im Checkout, faellt dort aber nicht auf: der fuehrende Punkt
// haelt es aus dem '*/'-Glob von changed-packages.sh heraus, und ungetrackt
// taucht es auch im git diff nicht auf. Ein Ordner ohne Punkt waere hier
// falsch - er wuerde als moegliches Paket mitgezaehlt.
//
// Aufgerufen wird immer als 'bash <pfad>': writeFile setzt kein
// Ausfuehrbar-Bit, und der Umweg ueber bash macht das auch unnoetig.
private String materializeScripts(String targetDir = '.ci-lib') {
    List names = ['changed-packages.sh', 'build-sdist.sh', 'sdist-meta.sh', 'publish-pypi.sh']
    names.each { n ->
        writeFile file: "${targetDir}/${n}",
                  text: libraryResource("de/firma/ci/${n}"),
                  encoding: 'UTF-8'
    }
    echo "Skripte nach ${targetDir}/ geschrieben: ${names.join(', ')}"
    return targetDir
}
EOF
```

- [ ] **Step 2: Strukturpruefung in den Testtreiber aufnehmen**

Kein Groovy-Compiler vorhanden, aber die eine Klasse Fehler, die hier real droht, ist pruefbar: dass `materializeScripts()` und die `sh`-Aufrufe eine andere Skriptmenge nennen als `resources/` hergibt. Fuege in `test/run-tests.sh` vor `echo "=== Bilanz ==="` ein:

```bash
echo
echo "=== vars/pyMonorepo.groovy ==="
GROOVY="${ROOT}/vars/pyMonorepo.groovy"
if [[ -f "$GROOVY" ]]; then
  ok "vars/pyMonorepo.groovy vorhanden"

  # Jedes Skript, das die Groovy-Datei nennt, muss es auch geben - und umgekehrt.
  NAMED="$(grep -oE '[a-z-]+\.sh' "$GROOVY" | sort -u)"
  HAVE="$(cd "$SCRIPTS" && ls *.sh | sort -u)"
  assert_eq "genannte Skripte == vorhandene Skripte" "$HAVE" "$NAMED"

  # Klammerbilanz - faengt den haeufigsten Copy-Paste-Fehler ab.
  OPEN="$(tr -cd '{' < "$GROOVY" | wc -c | tr -d ' ')"
  CLOSE="$(tr -cd '}' < "$GROOVY" | wc -c | tr -d ' ')"
  assert_eq "geschweifte Klammern ausgeglichen" "$OPEN" "$CLOSE"

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
```

- [ ] **Step 3: Tests laufen lassen**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh; echo "Exit: $?"
```

Erwartet: `FAIL 0`, Exit 0, ein zusaetzliches SKIP fuer `groovyc`.

- [ ] **Step 4: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add vars test/run-tests.sh
git commit -m "$(cat <<'EOF'
Pipeline als vars/pyMonorepo.groovy

Die Skripte kommen per libraryResource aus der Library und werden nach
.ci-lib geschrieben. Der fuehrende Punkt ist tragend: er haelt den Ordner
aus dem '*/'-Glob von changed-packages.sh heraus, sonst zaehlte er als
Paket mit. Stages, Parameter und post bleiben inhaltlich wie im
bisherigen Jenkinsfile.

Die Nexus-Werte gehen per withEnv um die Schritte, die sie brauchen,
statt ueber einen environment-Block: dieselbe Ueberlegung, aus der schon
bisher credentials() im environment vermieden wurde.

Nicht lokal verifizierbar - kein Groovy-Compiler und ohne Jenkins kein
Declarative-Block. Der Testtreiber prueft nur Struktur.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: examples/Jenkinsfile und README-ci.md

Die Vorlage fuer Monorepos und die Dokumentation, die heute noch den RAW-Weg beschreibt.

**Files:**
- Modify: `examples/Jenkinsfile` (ersetzt den in Task 1 verschobenen Inhalt vollstaendig)
- Modify: `README-ci.md`

**Interfaces:**
- Consumes: den Step `pyMonorepo(Closure)` mit den Config-Schluesseln aus Task 4
- Produces: nichts, was spaetere Tasks brauchen

- [ ] **Step 1: examples/Jenkinsfile ersetzen**

```bash
cd /Users/bengoo/projects/jenkins
cat > examples/Jenkinsfile <<'EOF'
// Vorlage: diese Datei gehoert als 'Jenkinsfile' in die Wurzel eines
// Python-Monorepos. Die Pipeline selbst liegt in der Shared Library
// 'ci-shared' - im Monorepo bleibt nur die Konfiguration.
//
// Der Job muss als Multibranch Pipeline oder "Pipeline from SCM" angelegt
// sein, sonst setzt das Git-Plugin GIT_PREVIOUS_SUCCESSFUL_COMMIT nicht und
// es wird jedes Mal alles gebaut.
@Library('ci-shared@v1.0.0') _

pyMonorepo {
    nexusUrl   = 'https://nexus.example.com'
    // HOSTED-Repo, nie die Group: Group-Repos nehmen keine Uploads an.
    hostedRepo = 'pypi-hosted'

    // Optional, hier mit ihren Defaults:
    // credentialsId = 'nexus-pypi-deploy'  // Username/Password-Credential in Jenkins
    // packages      = ''                   // leer = Auto-Erkennung der Paketordner
    // keepBuilds    = 30
}
EOF
```

- [ ] **Step 2: README-ci.md neu schreiben**

```bash
cd /Users/bengoo/projects/jenkins
cat > README-ci.md <<'EOF'
# ci-shared: Jenkins Shared Library fuer Python-Monorepos

Ermittelt die geaenderten Pakete eines Monorepos, baut je eine sdist und laedt
sie in ein Nexus-PyPI-**hosted**-Repo.

## Aufbau

    vars/pyMonorepo.groovy                 die Pipeline
    resources/de/firma/ci/
        changed-packages.sh                welche Top-Level-Ordner haben sich geaendert
        build-sdist.sh                     ein Ordner -> dist/<name>-<version>.tar.gz (echte sdist)
        sdist-meta.sh                      Name/Version aus der PKG-INFO der sdist
        publish-pypi.sh                    twine-Upload ins PyPI-hosted-Repo
    examples/Jenkinsfile                   Vorlage fuer die Wurzel eines Monorepos
    test/run-tests.sh                      Testtreiber

Die vier Skripte sind eigenstaendig und lokal testbar; die Pipeline ruft nur
auf. Sie liegen in `resources/` und werden zur Laufzeit per `libraryResource`
auf den Agent geschrieben - ein Monorepo braucht deshalb keinen `ci/`-Ordner.

## Einmalige Einrichtung

1. Nexus: PyPI-Repo vom Typ **hosted** anlegen. Group-Repos nehmen keine
   Uploads an, die sind nur zum Lesen da
   (`pip install -i .../repository/<group>/simple/`).
2. Jenkins: Credential vom Typ *Username with password* mit der ID
   `nexus-pypi-deploy`.
3. Jenkins: Manage Jenkins -> System -> Global Pipeline Libraries, dieses Repo
   unter dem Namen `ci-shared` eintragen.
4. Im Monorepo `examples/Jenkinsfile` als `Jenkinsfile` in die Wurzel legen und
   `nexusUrl` sowie `hostedRepo` anpassen.
5. Job als *Multibranch Pipeline* oder *Pipeline from SCM* anlegen - wichtig,
   damit `GIT_PREVIOUS_SUCCESSFUL_COMMIT` gesetzt wird.

## Konfiguration

| Schluessel | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `nexusUrl` | ja | -- | Basis-URL der Nexus-Instanz |
| `hostedRepo` | nein | `pypi-hosted` | HOSTED-Repo, nie die Group |
| `credentialsId` | nein | `nexus-pypi-deploy` | Username/Password-Credential |
| `packages` | nein | `''` | Feste Paketliste; leer heisst Auto-Erkennung |
| `keepBuilds` | nein | `30` | wie viele Builds aufgehoben werden |

Fehlt `nexusUrl`, bricht die Pipeline sofort ab statt erst beim Upload.

## Woher die Version kommt

Aus der `PKG-INFO` der **gebauten** sdist, nicht aus dem Ordnernamen und nicht
aus dem Dateinamen. Beides kann abweichen, weil setuptools normalisiert:

    Ordner  alpha    name="Mein.Tolles_Paket"  ->  mein_tolles_paket-...
    Version 1.0-1                              ->  1.0.post1  (PEP 440)

Ausserdem duerfen Paketnamen selbst Bindestriche enthalten - den Dateinamen zu
zerlegen waere also mehrdeutig. `build-sdist.sh` gibt den tatsaechlichen Pfad
aus, `sdist-meta.sh` liest Name und Version aus der `PKG-INFO`.

## Doppelte Versionen

Weil die Version aus dem Paket kommt, ist "zweimal dieselbe Version hochladen"
fast immer ein vergessener Version-Bump. Ein PyPI-hosted-Repo lehnt das mit 400
ab; `publish-pypi.sh` erkennt das und bricht mit Exit-Code 2 und klarer Meldung
ab, statt einen Infrastrukturfehler zu melden.

`publish-pypi.sh` prueft ausserdem vorab ueber die Nexus-REST-API, ob
`NEXUS_PYPI_HOSTED` wirklich ein hosted-PyPI-Repo ist (Exit 3 bei group oder
proxy). Ist die API nicht erreichbar oder fehlen die Rechte, wird nur gewarnt.
Abschalten mit `SKIP_REPO_CHECK=1`.

## Welche Pakete werden gebaut

`changed-packages.sh` erkennt Pakete als Top-Level-Ordner mit `pyproject.toml`,
`setup.py` oder `__init__.py`. Feste Liste stattdessen:

    packages = 'paket1 paket2'      // im Jenkinsfile
    PACKAGES="paket1 paket2" changed-packages.sh <base>     // lokal

Gebaut wird die Schnittmenge aus "ist ein Paket" und "liegt im `git diff` seit
dem letzten erfolgreichen Build". Drei Sonderfaelle bauen absichtlich alles:

* kein gueltiger Basis-Commit (erster Build, neuer Branch, History gepruned)
* `ci/` oder `Jenkinsfile` wurden geaendert
* Build mit Parameter `BUILD_ALL`

Nur bauen, nicht hochladen: Build-Parameter `SKIP_UPLOAD`.

## Lokal testen

Der Testtreiber laeuft ohne Netzwerk und meldet, was er mangels Werkzeug nicht
pruefen konnte, als SKIP:

    test/run-tests.sh

Einzelne Skripte von Hand, aus der Wurzel eines Monorepos:

    S=resources/de/firma/ci
    bash $S/changed-packages.sh HEAD~1
    bash $S/build-sdist.sh mein_paket           # gibt den Archivpfad aus
    bash $S/sdist-meta.sh dist/mein_paket-1.2.3.tar.gz name
    tar tzf dist/mein_paket-*.tar.gz | head

    NEXUS_URL=... NEXUS_PYPI_HOSTED=... NEXUS_USER=... NEXUS_PASS=... \
      bash $S/publish-pypi.sh dist/mein_paket-1.2.3.tar.gz

## Umgang mit den Zugangsdaten

Drei Stellen, an denen Nexus-Credentials ueblicherweise auslaufen - und wie es
hier vermieden wird.

**1. `environment { X = credentials(...) }`** bindet das Secret fuer die
*gesamte* Pipeline, also auch fuer jeden Schritt, den es nichts angeht. Deshalb
bindet `pyMonorepo` es per `withCredentials` direkt um den einen Upload-Schritt.

**2. Interpolation in Groovy-Strings.** Steht ein Secret in einem
Groovy-String, landet es im Prozessaufruf und damit potenziell im Log; Jenkins
warnt darueber explizit ("a secret was passed to an insecure Groovy String").
Hier wird nichts interpoliert: `withCredentials` legt `NEXUS_USER` und
`NEXUS_PASS` in die Umgebung, `publish-pypi.sh` liest sie von dort.

**3. argv.** `publish-pypi.sh` reicht die Zugangsdaten ueber
`TWINE_USERNAME`/`TWINE_PASSWORD` weiter, nicht als Kommandozeilenargument -
sonst stuenden sie in der Prozessliste. Der Repo-Typ-Check nutzt aus demselben
Grund `curl --config -`.

Wollt ihr Secrets ganz aus der Job-Konfiguration heraushalten, ist der naechste
Schritt ein Nexus-Token pro Team statt eines Deploy-Users, hinterlegt als
Jenkins-Credential mit Folder-Scope statt global.

## Migration eines bestehenden Monorepos

1. Library in Jenkins als `ci-shared` registrieren (siehe Einrichtung).
2. `Jenkinsfile` durch die Vorlage aus `examples/` ersetzen.
3. `ci/` im Monorepo loeschen, `.ci-lib/` in die `.gitignore` aufnehmen -
   dorthin schreibt die Library die Skripte zur Laufzeit.
4. Einmal mit `SKIP_UPLOAD` bauen und die Paketliste im Log gegen den alten
   Build vergleichen.
EOF
```

- [ ] **Step 3: Gegenpruefen, dass keine Reste der RAW-Generation uebrig sind**

```bash
cd /Users/bengoo/projects/jenkins
grep -rn 'NEXUS_REPO\|nexus-raw-deploy\|version-of\.sh\|pack\.sh\|upload-nexus\.sh' \
  --exclude-dir=.git --exclude-dir=docs . || echo "keine RAW-Reste"
```

Erwartet: `keine RAW-Reste`. Treffer unter `docs/` sind in Ordnung - die Spec beschreibt die Altlast bewusst.

- [ ] **Step 4: Die Config-Schluessel im README gegen die Groovy-Datei pruefen**

Ein README, das einen Schluessel nennt, den `call()` nicht kennt, ist schlimmer als keins:

Nur die erste Tabellenspalte auswerten, nicht die ganze Zeile: in der
Default-Spalte stehen Werte wie `pypi-hosted` und `nexus-pypi-deploy`, die sonst
als vermeintliche Schluessel mitgezaehlt wuerden.

```bash
cd /Users/bengoo/projects/jenkins

DOKU="$(sed -n '/^| Schluessel/,/^$/p' README-ci.md \
        | awk -F'|' 'NF>2 {gsub(/[ `]/,"",$2); print $2}' \
        | grep -vE '^(Schluessel|-*)$' | sort -u)"

# Die erste Zeile des Map-Literals ('Map cfg = [') muss raus, sonst zaehlt
# 'Map' als Schluessel mit.
CODE="$(sed -n '/Map cfg = \[/,/^    \]/p' vars/pyMonorepo.groovy \
        | grep -oE '^ {8}[a-zA-Z]+' | tr -d ' ' | sort -u)"

echo "--- im README dokumentiert:"; echo "$DOKU"
echo "--- in call() definiert:";    echo "$CODE"
if [[ "$DOKU" == "$CODE" ]]; then echo "OK: identisch"; else
  echo "ABWEICHUNG:"; diff <(echo "$DOKU") <(echo "$CODE"); fi
```

Erwartet: `OK: identisch`, mit den fuenf Schluesseln `credentialsId`,
`hostedRepo`, `keepBuilds`, `nexusUrl`, `packages`.

- [ ] **Step 5: Testtreiber ein letztes Mal laufen lassen**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh; echo "Exit: $?"
```

Erwartet: `FAIL 0`, Exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add examples README-ci.md
git commit -m "$(cat <<'EOF'
Vorlage und README auf die Shared Library umstellen

examples/Jenkinsfile ist jetzt die Konfigurationsvorlage fuer ein
Monorepo. Das README beschrieb durchgaengig die alte RAW-Generation
(NEXUS_REPO, nexus-raw-deploy, Ablage als <paket>/<version>/...) und
damit etwas anderes, als die Pipeline tut.

Die Abschnitte zu version-of.sh und zum HEAD-Check in upload-nexus.sh
entfallen mit den Skripten; an ihre Stelle treten PKG-INFO als
Versionsquelle und der 400-Fall beim Upload. Der Abschnitt zu
"Permission denied" ist gegenstandslos, seit die Skripte per writeFile
auf den Agent kommen und als 'bash <pfad>' gerufen werden.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Nach dem Plan: was offen bleibt

`vars/pyMonorepo.groovy` ist mit diesem Plan **nicht funktional verifiziert** —
die Strukturpruefung in Task 4 faengt Skript-Namensdrift und Klammerfehler,
mehr nicht. Der erste echte Test ist ein Lauf auf einem Jenkins:

1. Library als `ci-shared` registrieren.
2. Testjob auf ein Monorepo mit dem `examples/Jenkinsfile`, Build mit
   `BUILD_ALL` **und** `SKIP_UPLOAD`.
3. Im Log pruefen: die Zeile "Skripte aus der Library nach ... geschrieben"
   erscheint, die Paketliste stimmt, pro Paket wird eine sdist gebaut.
4. Danach ein Build ohne `SKIP_UPLOAD` gegen ein Test-Repo in Nexus.
