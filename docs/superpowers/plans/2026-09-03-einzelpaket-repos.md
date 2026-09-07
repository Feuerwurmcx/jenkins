# Einzelpaket-Repos — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `changed-packages.sh` erkennt Repos, deren Paket-Metadaten in der Repo-Wurzel liegen (statt in Top-Level-Paketordnern), als ein einziges Paket `.` — heute liefern solche Repos eine leere Liste, die Pipeline baut nichts und ist trotzdem gruen.

**Architecture:** Eine Funktion `root_is_package()` prueft die Repo-Wurzel auf `setup.py`, `setup.cfg` oder eine `pyproject.toml` mit verankertem `[project]`- bzw. `[tool.poetry]`-Abschnitt. Trifft sie zu, gibt `all_packages()` genau `.` aus und die Unterordner-Suche entfaellt; in der Schnittmenge zaehlt dann jede geaenderte Datei. Findet die Auto-Erkennung gar nichts, geht ein Hinweis nach stderr — der stille Leerlauf war der eigentliche Fehler.

**Tech Stack:** Bash (bash 3.2 tauglich), git, der bestehende Testtreiber `test/run-tests.sh` mit seinem python3-Stub.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-03-einzelpaket-repos-design.md`. Erkennungsregel, Muster und Festlegungen exakt von dort.
- Erkennungsmuster verankert: `^[[:space:]]*\[(project|tool\.poetry)\][[:space:]]*$`. `[project.optional-dependencies]` allein darf **nicht** zaehlen; eine `pyproject.toml` mit nur `[tool.black]`/`[tool.ruff]` darf ein Monorepo **nicht** in ein Einzelpaket verwandeln.
- Mischform (Wurzel-Metadaten **und** Paketordner): die Wurzel gewinnt, Ausgabe ist `.`.
- **`PACKAGES` gewinnt immer.** Ist `PACKAGES` gesetzt, greift weder die Wurzelerkennung noch der Hinweis.
- Der Hinweis bei null erkannten Paketen aendert **keinen** Exit-Code — ein Repo ohne Pakete ist kein Fehler.
- `set -euo pipefail`. Nutzdaten nach stdout, Hinweise nach stderr — der Aufrufer liest stdout als Paketliste.
- Kommentare und Meldungen auf Deutsch, im Stil des Bestands.
- macOS, `/bin/bash` 3.2, BSD sed/grep: `sed -i ''`, `[[:space:]]` statt `\s`, kein `mapfile`, keine assoziativen Arrays.
- Jeder neue Test braucht einen gezeigten Rotlauf. Eine **leere** Ausgabe beweist nichts — sie ist der heutige Zustand; jeder Einzelpaket-Fall muss auf die exakte Ausgabe `.` pruefen.
- Am Ende: `bash test/run-tests.sh` FAIL 0, Exit 0; `git status --short` leer.
- Commit-Betreff ohne Umlaute, Message auf Deutsch, endend mit `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

| Datei | Verantwortung |
|---|---|
| `resources/de/firma/ci/changed-packages.sh` | `root_is_package()`, Wurzelzweig in `all_packages()`, Einzelpaket-Zweig in der Schnittmenge, Hinweis bei null Paketen |
| `test/fixture-single/` | Fixture: ein Repo, das selbst ein Paket ist (Wurzel-`pyproject.toml` mit `[project]`, `src/`-Layout) |
| `test/run-tests.sh` | Helfer `fixture_single_repo`, neuer Block `=== changed-packages.sh: Einzelpaket-Repos ===` |
| `resources/de/firma/ci/build-sdist.sh` | nur die Logzeile fuer `.` |
| `vars/pyMonorepo.groovy` | nur das Stage-Label fuer `.` |
| `README-ci.md` | Abschnitt "Welche Pakete werden gebaut" |

---

## Task 1: Wurzelpaket-Erkennung und Hinweis

**Files:**
- Create: `test/fixture-single/pyproject.toml`, `test/fixture-single/src/einzelpaket/__init__.py`
- Modify: `test/run-tests.sh`
- Modify: `resources/de/firma/ci/changed-packages.sh`

**Interfaces:**
- Consumes: `ok`, `nok`, `assert_eq`, `assert_contains`, `$SCRIPTS`, `$TMP` aus `test/run-tests.sh`; das Muster von `fixture_repo` als Vorlage.
- Produces: `bash changed-packages.sh <base>` gibt bei einem Repo mit Wurzel-Metadaten genau `.` aus (eine Zeile). Alles andere unveraendert. Neue private Funktionen `root_is_package` (kein anderes Skript ruft sie) und der Helfer `fixture_single_repo` im Testtreiber, den Task 2 wiederverwendet.

- [ ] **Step 1: Fixture anlegen**

```bash
cd /Users/bengoo/projects/jenkins
mkdir -p test/fixture-single/src/einzelpaket
cat > test/fixture-single/pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"

[project]
name = "einzelpaket"
version = "1.0.0"

[tool.setuptools.packages.find]
where = ["src"]
EOF
: > test/fixture-single/src/einzelpaket/__init__.py
```

- [ ] **Step 2: Testhelfer und Tests einfuegen**

Fuege in `test/run-tests.sh` direkt hinter der Funktion `fixture_repo` ein:

```bash
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
```

Fuege danach, direkt vor `echo "=== Bilanz ==="`, den neuen Testblock ein:

```bash
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

( cd "$SREPO" && git commit -q --allow-empty -m leer )
assert_eq "Einzelpaket, nichts geaendert -> leer" "" \
  "$(cd "$SREPO" && $CP HEAD~1 2>/dev/null)"

# setup.py in der Wurzel genuegt, ohne pyproject.toml.
RSETUP="$(make_root_repo setuppy "")"
( cd "$RSETUP" && echo "from setuptools import setup" > setup.py && git add -A && git commit -q -m setup )
assert_eq "Wurzel mit setup.py -> ." "." \
  "$(cd "$RSETUP" && $CP '' 2>/dev/null)"

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

# Mischform: Wurzel-[project] UND ein Paketordner -> die Wurzel gewinnt.
RMIX="$(make_root_repo mixed '[project]
name = "m"
version = "1.0"')"
assert_eq "Mischform -> Wurzel gewinnt" "." \
  "$(cd "$RMIX" && $CP '' 2>/dev/null)"

# PACKAGES gewinnt auch gegen die Wurzelerkennung.
assert_eq "PACKAGES gewinnt gegen die Wurzelerkennung" "alpha" \
  "$(cd "$RMIX" && PACKAGES='alpha' $CP '' 2>/dev/null)"

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
```

- [ ] **Step 3: Tests laufen lassen — Rotlauf**

```bash
cd /Users/bengoo/projects/jenkins
bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL-Zeilen: %s\n'
bash test/run-tests.sh 2>&1 | grep -E '^FAIL' | head -12
```

Erwartet: Exit 1. Rot sind alle sechs Faelle, die `.` erwarten (`Wurzel mit [project]`, `Datei unter src/ geaendert`, `Wurzel mit setup.py`, `Wurzel mit [tool.poetry]`, `Mischform`), sowie der Hinweis-Fall — das heutige Skript gibt dort jeweils Leerstring bzw. `alpha` aus und schreibt keinen Hinweis.

**Nicht rot, und das ist richtig so:** `Wurzel nur mit [tool.black]`, `nur [project.optional-dependencies]`, `PACKAGES gewinnt`, `nichts geaendert -> leer` und `PACKAGES gesetzt -> kein Hinweis` — das heutige Verhalten ist dort schon das gewuenschte. Sie sichern nach Step 4 gegen Regressionen ab. Halte im Report fest, welche Assertions rot waren; ist eine der als rot erwarteten gruen, pruef sie einzeln.

- [ ] **Step 4: `changed-packages.sh` erweitern**

(a) Fuege direkt **vor** `all_packages()` ein:

```bash
# Hat die Repo-Wurzel selbst Paket-Metadaten? Dann ist das Repo EIN Paket und
# kein Monorepo mit Paketordnern - so gebaut sind z. B. Repos mit src-Layout,
# bei denen die Unterordner von src/ Import-Pakete derselben Distribution sind
# und keine eigenen Metadaten haben.
#
# Bei pyproject.toml genuegt die blosse Datei nicht: sie enthaelt oft nur
# Werkzeugkonfiguration ([tool.black], [tool.ruff]) und steht dann auch in
# einem echten Monorepo in der Wurzel. Erst ein [project]- oder
# [tool.poetry]-Abschnitt macht daraus ein Distributionspaket. Die Muster sind
# verankert, damit [project.optional-dependencies] allein nicht zaehlt.
root_is_package() {
  [[ -f setup.py || -f setup.cfg ]] && return 0
  [[ -f pyproject.toml ]] || return 1
  grep -qE '^[[:space:]]*\[(project|tool\.poetry)\][[:space:]]*$' pyproject.toml
}
```

(b) In `all_packages()`, direkt **nach** dem `PACKAGES`-Block (also nach dessen `return`) und **vor** der `for d in */`-Schleife:

```bash
  if root_is_package; then
    printf '%s\n' '.'
    return
  fi
```

(c) Die `for d in */`-Schleife am Ende von `all_packages()` so umbauen, dass sie den Hinweis geben kann. Ersetze

```bash
  local d
  for d in */; do
    d="${d%/}"
    if [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/setup.cfg" ]]; then
      printf '%s\n' "$d"
    fi
  done | sort -u
```

durch

```bash
  local d found
  found="$(
    for d in */; do
      d="${d%/}"
      if [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/setup.cfg" ]]; then
        printf '%s\n' "$d"
      fi
    done | sort -u
  )"
  if [[ -z "$found" ]]; then
    # Der stille Leerlauf war der eigentliche Fehler: ein Repo, das nichts
    # baut, war bisher nicht von einem Repo ohne Aenderungen zu unterscheiden.
    # Exit-Code bleibt 0 - ein Repo ohne Pakete ist kein Fehler.
    echo "HINWEIS: keine Paketordner und keine Paket-Metadaten in der" >&2
    echo "         Repo-Wurzel gefunden - es wird nichts gebaut. Erwartet" >&2
    echo "         werden entweder Top-Level-Ordner mit pyproject.toml," >&2
    echo "         setup.py oder setup.cfg, oder dieselben Metadaten in der" >&2
    echo "         Repo-Wurzel." >&2
    return
  fi
  printf '%s\n' "$found"
```

(d) In der Schnittmenge, direkt **nach** dem `ci/`-`Jenkinsfile`-Block und **vor** der Zeile `TOUCHED=...`:

```bash
# Beim Einzelpaket zaehlt jede geaenderte Datei: die Zuordnung ueber die erste
# Pfadkomponente gibt es dort nicht, das Paket IST das Repo. Genau daran
# scheitert der Umweg ueber PACKAGES='.' - die Schnittmenge enthaelt nie '.'.
# Die PACKAGES-Pruefung steht davor, damit eine explizit gesetzte Liste auch
# hier gewinnt.
if [[ -z "${PACKAGES:-}" ]] && root_is_package; then
  if [[ -n "$CHANGED_FILES" ]]; then
    printf '%s\n' '.'
  fi
  exit 0
fi
```

(e) Den Kopfkommentar des Skripts um zwei Saetze ergaenzen: dass ein Repo mit Paket-Metadaten in der Wurzel als ein Paket `.` gilt und die Unterordner-Suche dann entfaellt.

- [ ] **Step 5: Tests laufen lassen — gruen**

```bash
bash test/run-tests.sh 2>&1 | tail -2; bash test/run-tests.sh >/dev/null 2>&1; echo "Exit: $?"
```

Erwartet: FAIL 0, Exit 0.

- [ ] **Step 6: Gegen die echten Repos pruefen**

Diese beiden Repos haben das Problem ausgeloest; sie liegen lokal und sind der eigentliche Abnahmetest. **Nur lesen, nichts darin aendern.**

```bash
cd /Users/bengoo/projects/jenkins
S=resources/de/firma/ci
for p in /Users/bengoo/projects/amm/dpl-examples/submodules/dpl-components \
         /Users/bengoo/projects/amm/dpl-core; do
  printf '%-16s -> [%s]\n' "$(basename "$p")" \
    "$(cd "$p" && bash "$OLDPWD/$S/changed-packages.sh" '' 2>/dev/null | tr '\n' ' ')"
done
```

Erwartet: beide melden `.` statt wie bisher nichts. Uebernimm die echte Ausgabe in den Report. Meldet eines der beiden weiterhin nichts, ist das ein Befund — melden, nicht die Erkennung daran anpassen, bis klar ist warum.

- [ ] **Step 7: Gegenproben**

Nach jeder Mutation mit `cmp` gegen die Sicherung bestaetigen, dass sie geschrieben hat; danach zuruecksetzen.

```bash
cd /Users/bengoo/projects/jenkins
S=resources/de/firma/ci/changed-packages.sh; BAK="$(mktemp)"; cp $S "$BAK"
probe() { printf '%-46s ' "$1"; cmp -s $S "$BAK" && { echo "NICHT ANGEWENDET"; return; }
  bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL-Zeilen: %s\n'; cp "$BAK" $S; }

# (a) Wurzelzweig aus all_packages entfernt -> die '.'-Faelle rot
python3 -c 'import io,re;p="resources/de/firma/ci/changed-packages.sh";s=io.open(p).read();s=re.sub(r"  if root_is_package; then\n    printf .%s\\\\n. .\..\n    return\n  fi\n","",s,count=1);io.open(p,"w").write(s)'
probe "(a) Wurzelzweig in all_packages entfernt"

# (b) Verankerung weg -> [project.optional-dependencies] zaehlt faelschlich
python3 -c 'import io;p="resources/de/firma/ci/changed-packages.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("^[[:space:]]*\\[(project|tool\\.poetry)\\][[:space:]]*$","\\[(project|tool\\.poetry)"))'
probe "(b) Erkennungsmuster nicht mehr verankert"

# (c) PACKAGES-Vorrang im Schnittmengen-Zweig entfernt
python3 -c 'import io;p="resources/de/firma/ci/changed-packages.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("if [[ -z \"${PACKAGES:-}\" ]] && root_is_package; then","if root_is_package; then"))'
probe "(c) PACKAGES-Vorrang entfernt"

# (d) Hinweis entfernt
python3 -c 'import io,re;p="resources/de/firma/ci/changed-packages.sh";s=io.open(p).read();s=re.sub(r"    echo \"HINWEIS: keine Paketordner.*?Repo-Wurzel\.\" >&2\n","",s,flags=re.S);io.open(p,"w").write(s)'
probe "(d) Hinweis bei null Paketen entfernt"

cp "$BAK" $S; rm "$BAK"; git status --short; echo "(leer = wiederhergestellt)"
```

Erwartet: jede Zeile meldet mindestens eine FAIL-Zeile. Bleibt eine angewendete Mutation gruen, ist das ein Befund — melden, nicht die Mutation anpassen.

- [ ] **Step 8: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add resources/de/firma/ci/changed-packages.sh test/run-tests.sh test/fixture-single
git commit -m "$(cat <<'EOF'
changed-packages.sh: Repos mit Metadaten in der Wurzel als ein Paket erkennen

Repos, die selbst ein Paket sind - pyproject.toml in der Wurzel, Quellcode
unter src/ -, hatten keinen Top-Level-Paketordner und lieferten deshalb
eine leere Liste: die Pipeline baute nichts und war trotzdem gruen.
Kuenftig gilt ein Repo mit setup.py, setup.cfg oder einer pyproject.toml
mit [project]- bzw. [tool.poetry]-Abschnitt als ein Paket namens ".", und
jede geaenderte Datei zaehlt dafuer.

Die Muster sind verankert, damit weder [project.optional-dependencies]
allein noch eine pyproject.toml mit reiner Werkzeugkonfiguration ein
Monorepo faelschlich in ein Einzelpaket verwandelt. PACKAGES gewinnt
weiterhin gegen beide Erkennungswege.

Dazu ein Hinweis auf stderr, wenn gar kein Paket erkannt wird - der
stille Leerlauf war der eigentliche Fehler.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Logzeile, Stage-Label und Doku

**Files:**
- Modify: `resources/de/firma/ci/build-sdist.sh` (nur die Logzeile)
- Modify: `vars/pyMonorepo.groovy` (nur das Stage-Label)
- Modify: `test/run-tests.sh` (zwei Assertions)
- Modify: `README-ci.md`

**Interfaces:**
- Consumes: `fixture_single_repo` und `make_root_repo` aus Task 1; den vorhandenen python3-Stub (`make_python_stub`, `STUB_NAME`/`STUB_VERSION`) und die Strukturtest-Helfer `step_body`.
- Produces: nichts fuer spaetere Tasks.

- [ ] **Step 1: Tests zuerst**

Fuege in `test/run-tests.sh` im Block `=== build-sdist.sh ===`, direkt nach dem bestehenden Happy-Path-Test mit dem python3-Stub, ein:

```bash
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
```

Und im Strukturtest-Block `=== vars/pyMonorepo.groovy ===`, bei den `build()`-Pins:

```bash
  assert_contains "build(): Stage-Label fuer das Wurzelpaket" "$BUILD_MAP_BODY" "Wurzelpaket"
```

- [ ] **Step 2: Rotlauf**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh 2>&1 | grep -E '^FAIL'
```

Erwartet: rot sind `build-sdist.sh . meldet 'Repo-Wurzel'`, `vermeidet "Ordner '.'"` und `Stage-Label fuer das Wurzelpaket`. Die zwei Assertions auf `rc 0` und `dist/` sind bereits gruen — `build-sdist.sh .` funktioniert schon heute, nur die Meldung stimmt nicht. Das ist erwartet; halte es im Report fest.

- [ ] **Step 3: Logzeile in build-sdist.sh**

Ersetze die Zeile

```bash
echo "Ordner '${PKG}' -> ${DIST_NAME} ${DIST_VER}" >&2
```

durch

```bash
# Bei '.' ist das Repo selbst das Paket - "Ordner '.'" waere missverstaendlich.
if [[ "$PKG" == "." ]]; then
  echo "Repo-Wurzel -> ${DIST_NAME} ${DIST_VER}" >&2
else
  echo "Ordner '${PKG}' -> ${DIST_NAME} ${DIST_VER}" >&2
fi
```

- [ ] **Step 4: Stage-Label in vars/pyMonorepo.groovy**

Ersetze in `build()` die Zeile

```groovy
                stage(pkg) {
```

durch

```groovy
                // '.' ist das Repo selbst (Paket-Metadaten in der Wurzel).
                // Eine Stage namens '.' waere im Blue Ocean unlesbar.
                stage(pkg == '.' ? 'Wurzelpaket' : pkg) {
```

Der Wert, der an `build-sdist.sh` geht, bleibt `.` — nur das Label aendert sich.

- [ ] **Step 5: README ergaenzen**

Im Abschnitt "Welche Pakete werden gebaut", nach der Beschreibung der Top-Level-Erkennung, einfuegen:

```markdown
Manche Repos sind selbst ein einziges Paket: die `pyproject.toml` liegt in der
Repo-Wurzel, der Quellcode unter `src/`. Dort gibt es keinen Top-Level-
Paketordner. Solche Repos werden als ein Paket namens `.` erkannt, und **jede**
geaenderte Datei zaehlt als Aenderung an diesem Paket. Im Build-Log heisst die
Stage dann `Wurzelpaket`.

Als Paket-Metadaten in der Wurzel gilt eine `setup.py`, eine `setup.cfg`, oder
eine `pyproject.toml` mit einem `[project]`- bzw. `[tool.poetry]`-Abschnitt.
Die blosse Datei genuegt nicht: eine `pyproject.toml`, die nur
Werkzeugkonfiguration enthaelt (`[tool.black]`, `[tool.ruff]`), steht auch in
einem echten Monorepo in der Wurzel und darf es nicht in ein Einzelpaket
verwandeln. `[project.optional-dependencies]` allein zaehlt ebenfalls nicht.

Hat ein Repo **beides** - Metadaten in der Wurzel und Paketordner darunter -,
gewinnt die Wurzel: es gilt als ein Paket. Wer das nicht will, setzt
`packages` ausdruecklich; eine feste Liste gewinnt immer.

Wird gar kein Paket erkannt, meldet `changed-packages.sh` das auf stderr:

    HINWEIS: keine Paketordner und keine Paket-Metadaten in der Repo-Wurzel
             gefunden - es wird nichts gebaut.

Der Build bleibt dabei gruen - ein Repo ohne Pakete ist kein Fehler -, aber die
Zeile steht im Log. Fehlt sie und wird trotzdem nichts gebaut, liegt es nicht
an der Erkennung.
```

- [ ] **Step 6: Gruenlauf und Gegenproben**

```bash
cd /Users/bengoo/projects/jenkins
bash test/run-tests.sh 2>&1 | tail -2
G=vars/pyMonorepo.groovy; B=resources/de/firma/ci/build-sdist.sh
BAKG="$(mktemp)"; cp $G "$BAKG"; BAKB="$(mktemp)"; cp $B "$BAKB"
python3 -c 'import io;p="vars/pyMonorepo.groovy";s=io.open(p).read();io.open(p,"w").write(s.replace("stage(pkg == \x27.\x27 ? \x27Wurzelpaket\x27 : pkg)","stage(pkg)"))'
printf '%-40s ' "Stage-Label zurueckgebaut"; bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL: %s\n'; cp "$BAKG" $G
python3 -c 'import io;p="resources/de/firma/ci/build-sdist.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("Repo-Wurzel ->","Ordner (.) ->"))'
printf '%-40s ' "Repo-Wurzel-Meldung zurueckgebaut"; bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL: %s\n'; cp "$BAKB" $B
rm "$BAKG" "$BAKB"; git status --short; echo "(leer = wiederhergestellt)"
```

Erwartet: beide Mutationen mindestens eine FAIL-Zeile, danach sauberer Arbeitsbaum.

- [ ] **Step 7: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add resources/de/firma/ci/build-sdist.sh vars/pyMonorepo.groovy test/run-tests.sh README-ci.md
git commit -m "$(cat <<'EOF'
Wurzelpaket im Log und in der Doku benennen

build-sdist.sh meldet fuer '.' jetzt "Repo-Wurzel ->" statt "Ordner '.'",
und die Stage in build() heisst "Wurzelpaket" statt ".". Das README
beschreibt die Erkennungsregel, die Abgrenzung zur reinen
Werkzeugkonfiguration, die Festlegung zur Mischform und den Hinweis, der
erscheint, wenn gar kein Paket erkannt wird.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Nach dem Plan

1. Einen Build von `dpl-components` oder `dpl-core` mit `SKIP_UPLOAD` laufen lassen. Erwartet: eine Stage `Wurzelpaket`, im Log `Repo-Wurzel -> dpl-components 0.2.12`.
2. Kommt stattdessen `HINWEIS: keine Paketordner ...`, greift die Erkennung nicht — dann die Wurzel-`pyproject.toml` des Repos auf einen verankerten `[project]`-Abschnitt pruefen.
3. Pruefen, ob weitere Bitbucket-Repos dieser Bauart sind. `dpl-skill` hat gar keine `pyproject.toml` und bleibt auch danach kein Paket.
