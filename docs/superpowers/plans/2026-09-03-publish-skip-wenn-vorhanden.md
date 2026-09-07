# Upload ueberspringen wenn vorhanden — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `publish-pypi.sh` fragt vor dem Upload den Simple-Index des Ziel-Repos ab und ueberspringt den Upload mit Exit 0, wenn die Datei dort schon gelistet ist; der bisherige Exit 2 fuer Duplikate entfaellt.

**Architecture:** Eine Funktion `already_published()` holt den Paketnamen ueber `sdist-meta.sh` aus der PKG-INFO, normalisiert ihn nach PEP 503 und fragt `/repository/<repo>/simple/<name>/` ab. Aus der Antwort werden die Link-Texte extrahiert und exakt gegen den Dateinamen verglichen. Die Pruefung ist eine Abkuerzung, kein Gate: laesst sie sich nicht durchfuehren, wird gewarnt und normal hochgeladen; ein Duplikat faengt dann der 400-Pfad ab, der ebenfalls ueberspringt.

**Tech Stack:** Bash (bash 3.2 tauglich), `curl`, `sed`/`tr`/`grep`, Nexus 3 Simple-Index (PEP 503).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-03-publish-skip-wenn-vorhanden-design.md`. Statuszuordnung, Exit-Codes und Meldungstexte exakt von dort.
- Umfang: **nur** `resources/de/firma/ci/publish-pypi.sh`, `test/run-tests.sh` und Doku. `build-sdist.sh`, `sdist-meta.sh`, `changed-packages.sh`, `vars/pyMonorepo.groovy` und `examples/` werden **nicht** geaendert (`sdist-meta.sh` wird nur aufgerufen).
- Exit-Codes danach: 0 = hochgeladen ODER uebersprungen, 1 = sonstiger Fehler, 3 = falscher Repo-Typ. **Exit 2 kommt nicht mehr vor.**
- `set -euo pipefail` und `set +x` bleiben. Fehler und Hinweise nach stderr, Nutzdaten nach stdout.
- Zugangsdaten gehen NIE ueber argv — auch die neue Index-Abfrage nutzt `cfg_credentials | curl --config -`.
- Kommentare und Meldungen auf Deutsch, im Stil des Bestands.
- macOS, `/bin/bash` 3.2, BSD sed/grep: `sed -i ''`, `[[:space:]]` statt `\s`, kein `mapfile`, keine assoziativen Arrays.
- Jeder neue Test braucht einen gezeigten Rotlauf.
- Am Ende: `bash test/run-tests.sh` FAIL 0, Exit 0; `git status --short` leer.
- Commit-Betreff ohne Umlaute, Message auf Deutsch, endend mit `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

| Datei | Verantwortung |
|---|---|
| `resources/de/firma/ci/publish-pypi.sh` | `normalize_name`, `already_published`, geaenderter 400-Pfad |
| `test/run-tests.sh` | `make_curl_stub` unterscheidet drei Aufrufarten; neuer Block `=== publish-pypi.sh Vorabpruefung (Simple-Index) ===`; **zwei bestehende Tests muessen angepasst werden** (siehe Task 1 Step 1) |
| `README-ci.md` | Abschnitt "Doppelte Versionen", Exit-Code-Liste |
| `docs/superpowers/specs/2026-09-03-publish-ohne-twine-design.md` | Nachtrag: die dortige Exit-2-Regel ist ersetzt |

---

## Task 1: Vorabpruefung einbauen

**Files:**
- Modify: `test/run-tests.sh`
- Modify: `resources/de/firma/ci/publish-pypi.sh`

**Interfaces:**
- Consumes: `sdist-meta.sh <archiv> name` (liefert den Namen aus der PKG-INFO auf stdout); die Testhelfer `ok`, `nok`, `assert_eq`, `assert_rc`, `assert_contains`, `make_sdist`, `make_curl_stub`, `$SCRIPTS`, `$TMP`, `$ARCHIVE`.
- Produces: `bash publish-pypi.sh <archiv>` mit unveraenderter Signatur; Exit 0 bei Upload **und** bei Skip, 1 bei sonstigen Fehlern, 3 bei falschem Repo-Typ. Neue private Funktionen `normalize_name` und `already_published` (kein anderes Skript ruft sie).

- [ ] **Step 1: Bestehende Tests anpassen, die der zusaetzliche curl-Aufruf bricht**

Vier Stellen in `test/run-tests.sh` haengen an der bisherigen Aufrufzahl bzw. an Exit 2. **Zuerst anpassen**, sonst laesst sich der Rotlauf in Step 3 nicht von echten Regressionen unterscheiden.

Beide Zaehlungen zaehlen Vorkommen von `^--config$` in `curl-args` — jeder curl-Aufruf traegt genau eines. Mit der Vorabpruefung kommt je ein Aufruf dazu.

(a) Zeile ~997, `SKIP_REPO_CHECK=1`: bisher ein Aufruf (Upload), kuenftig zwei (Index + Upload). Ersetze

```bash
assert_eq "SKIP_REPO_CHECK=1 -> genau ein curl-Aufruf" "1" \
```

durch

```bash
# Zwei Aufrufe seit der Vorabpruefung: Simple-Index und Upload. Der
# Repo-Typ-Check kommt bei SKIP_REPO_CHECK=1 nicht dazu.
assert_eq "SKIP_REPO_CHECK=1 -> Index und Upload, kein Repo-Check" "2" \
```

(b) Zeile ~1144, ohne `SKIP_REPO_CHECK`: bisher zwei Aufrufe (Repo-Check + Upload), kuenftig **drei** (Repo-Check + Index + Upload). Ersetze

```bash
assert_eq "ohne SKIP_REPO_CHECK -> genau zwei curl-Aufrufe" "2" \
```

durch

```bash
assert_eq "ohne SKIP_REPO_CHECK -> Repo-Check, Index und Upload" "3" \
```

und zieh den Kommentar zwei Zeilen darueber nach: es laufen jetzt Repo-Typ-Check, Vorabpruefung und Upload.

(c) und (d), Zeilen ~1005 und ~1010: die beiden Duplikat-Faelle erwarten heute `rc 2`. Ersetze

```bash
assert_rc "400 + does not allow updating -> rc 2" 2 "$PUB_RC"
```
durch
```bash
assert_rc "400 + does not allow updating -> rc 0 (uebersprungen)" 0 "$PUB_RC"
assert_contains "400 + does not allow updating -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
```
und
```bash
assert_rc "400 + already exists -> rc 2" 2 "$PUB_RC"
```
durch
```bash
assert_rc "400 + already exists -> rc 0 (uebersprungen)" 0 "$PUB_RC"
assert_contains "400 + already exists -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
```

Der Kommentarblock bei Zeile ~1034 (Q-7, "400 im Dateinamen") erwaehnt `rc 2`; zieh den Text auf `rc 1` nach — der zugehoerige Test erwartet schon heute `rc 1` und bleibt inhaltlich richtig.

- [ ] **Step 2: curl-Stub auf drei Aufrufarten umstellen**

Der Stub unterscheidet heute an der Anwesenheit von `--output`. Die Index-Abfrage nutzt `--output` ebenfalls, das Kriterium traegt also nicht mehr. Ersetze in `make_curl_stub` den Block von `# Zwei Aufrufarten unterscheiden:` bis einschliesslich der `if [[ -z "$out" ]]`-Klammer durch:

```bash
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

case "$url" in
  */service/rest/v1/repositories)
    printf '%s' "${STUB_REPOS_JSON:-[]}"
    exit 0 ;;
  */simple/*)
    # Default 404: Paket unbekannt -> alle Bestandstests laden weiterhin hoch.
    if [[ -n "$out" ]]; then printf '%s' "${STUB_INDEX_BODY:-}" > "$out"; fi
    if [[ "$write_out" == 1 ]]; then printf '%s' "${STUB_INDEX_HTTP:-404}"; fi
    exit "${STUB_INDEX_CURL_RC:-0}" ;;
esac
```

Der Rest des Stubs (Upload-Zweig mit `STUB_BODY`, `STUB_HTTP`, `STUB_CURL_RC`, `STUB_CURL_STDERR`) bleibt unveraendert.

- [ ] **Step 3: Tests fuer die Vorabpruefung einfuegen**

Fuege in `test/run-tests.sh` direkt vor `skip "publish-pypi.sh echter Netzwerk-Upload"` ein:

```bash
echo
echo "=== publish-pypi.sh Vorabpruefung (Simple-Index) ==="
# $ARCHIVE stammt aus make_sdist mit Name 'Mein.Tolles_Paket' - der
# normalisierte Name im Index-Pfad muss also 'mein-tolles-paket' sein.
ARCHIVE_BASE="$(basename "$ARCHIVE")"

# Nutzung: run_publish_index <unterordner> [VAR=wert ...]
# Ergebnis in $PUB_OUT, $PUB_RC, $PUB_ARGS, $PUB_UPLOADS (Zahl der
# Upload-Aufrufe - daran haengt der Nachweis, dass wirklich uebersprungen wird).
run_publish_index() {
  local sub="$1"; shift
  PUB_D="${TMP}/pubidx-${sub}"
  rm -rf "$PUB_D"; mkdir -p "$PUB_D"
  PUB_OUT="$(env "$@" PATH="${CURL_BIN}:${PATH}" STUB_DIR="$PUB_D" \
             SKIP_REPO_CHECK=1 \
             NEXUS_URL=https://nexus.example.com \
             NEXUS_PYPI_HOSTED=pypi-hosted \
             NEXUS_USER=u NEXUS_PASS=p \
             bash "$SCRIPTS/publish-pypi.sh" "$ARCHIVE" 2>&1)"
  PUB_RC=$?
  PUB_ARGS="$(cat "${PUB_D}/curl-args" 2>/dev/null || true)"
  PUB_UPLOADS="$(grep -c 'service/rest/v1/components' <<<"$PUB_ARGS" || true)"
}

# Achtung: rc 0 allein beweist hier nichts - der erfolgreiche Upload liefert
# ebenfalls 0. Den Skip belegen die SKIP-Meldung UND $PUB_UPLOADS == 0.
run_publish_index hit STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<html><body><a href=\"../../packages/x/1/${ARCHIVE_BASE}#sha256=abc\">${ARCHIVE_BASE}</a></body></html>"
assert_rc "Index-Treffer -> rc 0" 0 "$PUB_RC"
assert_contains "Index-Treffer -> SKIP-Meldung" "$PUB_OUT" "SKIP:"
assert_eq "Index-Treffer -> kein Upload-Aufruf" "0" "$PUB_UPLOADS"
assert_contains "Index-URL nutzt den PEP-503-Namen" "$PUB_ARGS" "simple/mein-tolles-paket/"

run_publish_index miss STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">ein-anderes-1.0.tar.gz</a>"
assert_rc "Index ohne Treffer -> rc 0" 0 "$PUB_RC"
assert_contains "Index ohne Treffer -> OK-Meldung" "$PUB_OUT" "OK:"
assert_eq "Index ohne Treffer -> genau ein Upload-Aufruf" "1" "$PUB_UPLOADS"

# Exakter Vergleich statt Substring: '<datei>' darf nicht in '<datei>.asc'
# gefunden werden.
run_publish_index asc STUB_INDEX_HTTP=200 \
  STUB_INDEX_BODY="<a href=\"x\">${ARCHIVE_BASE}.asc</a>"
assert_eq "nur .asc gelistet -> kein Skip" "1" "$PUB_UPLOADS"
assert_contains "nur .asc gelistet -> OK-Meldung" "$PUB_OUT" "OK:"

run_publish_index notfound STUB_INDEX_HTTP=404
assert_eq "Index 404 -> Upload laeuft" "1" "$PUB_UPLOADS"
assert_rc "Index 404 -> rc 0" 0 "$PUB_RC"

run_publish_index unauth STUB_INDEX_HTTP=401
assert_eq "Index 401 -> Upload laeuft trotzdem" "1" "$PUB_UPLOADS"
assert_contains "Index 401 -> Hinweis auf die uebersprungene Pruefung" "$PUB_OUT" "Vorabpruefung uebersprungen"
assert_rc "Index 401 -> rc 0" 0 "$PUB_RC"

run_publish_index idxfail STUB_INDEX_CURL_RC=7
assert_eq "curl-Fehler beim Index -> Upload laeuft" "1" "$PUB_UPLOADS"
assert_contains "curl-Fehler beim Index -> Hinweis" "$PUB_OUT" "Vorabpruefung uebersprungen"

# Der 400-Pfad faengt ab, was die Vorabpruefung verpasst hat (Rennen zweier
# Builds, oder Index nicht abfragbar) - und ueberspringt jetzt ebenfalls.
run_publish_index dup400 STUB_INDEX_HTTP=404 STUB_HTTP=400 \
  STUB_BODY='{"message":"Repository does not allow updating assets"}'
assert_rc "400 trotz Vorabpruefung -> rc 0" 0 "$PUB_RC"
assert_contains "400 trotz Vorabpruefung -> SKIP-Meldung" "$PUB_OUT" "SKIP:"

```

- [ ] **Step 4: Tests laufen lassen — Rotlauf**

```bash
bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL-Zeilen: %s\n'
bash test/run-tests.sh 2>&1 | grep -E '^FAIL' | head -20
```

Erwartet: Exit 1. Rot sind alle Assertions des neuen Blocks, die einen Skip oder die Index-URL erwarten (`Index-Treffer -> SKIP-Meldung`, `kein Upload-Aufruf`, `Index-URL nutzt den PEP-503-Namen`, `Index 401 -> Hinweis`, `curl-Fehler beim Index -> Hinweis`), plus die vier in Step 1 auf `rc 0`/`SKIP:` umgestellten Duplikat-Assertions und **beide** Aufrufzaehlungen aus Step 1a/1b (das heutige Skript macht einen bzw. zwei Aufrufe, erwartet werden zwei bzw. drei).

**Nicht rot, und das ist richtig so:** `Index ohne Treffer -> rc 0`, `Index 404 -> rc 0`, `nur .asc gelistet -> kein Skip` und die `-> genau ein Upload-Aufruf`-Zaehlungen — das heutige Skript laedt immer hoch, verhaelt sich in diesen Faellen also schon wie gewuenscht. Sie beweisen erst nach Step 5 etwas, gemeinsam mit ihren Nachbarn. Halte im Report fest, welche Assertions rot waren.

- [ ] **Step 5: `publish-pypi.sh` erweitern**

(a) Direkt nach der Zeile `UPLOAD_URL="${BASE}/service/rest/v1/components?repository=${NEXUS_PYPI_HOSTED}"` einfuegen:

```bash
# Verzeichnis dieses Skripts - dort liegt auch sdist-meta.sh. Zur Laufzeit ist
# das .ci-lib auf dem Agent, lokal resources/de/firma/ci.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

(b) Nach der Zeile `[[ "${SKIP_REPO_CHECK:-0}" == "1" ]] || check_repo_type` einfuegen:

```bash
# --- Liegt die Datei schon im Repo? -----------------------------------------
# PEP 503: alles klein, und -, _ und . in beliebiger Wiederholung zu einem -.
# 'Mein.Tolles_Paket' wird damit zu 'mein-tolles-paket'.
normalize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
}

# Fragt den Simple-Index (PEP 503) - dieselbe API, die auch pip liest. Gibt 0
# zurueck, wenn der Dateiname dort exakt gelistet ist.
#
# Das ist eine Abkuerzung, kein Gate: laesst sich der Index nicht abfragen
# (keine Rechte, unerwarteter Status, curl scheitert), wird nur gewarnt und
# normal hochgeladen. Ein Duplikat faengt dann der 400-Pfad ab, der ebenfalls
# ueberspringt. Eine nicht durchfuehrbare Pruefung darf den Build nicht rot
# machen - dieselbe Logik wie beim Repo-Typ-Check.
already_published() {
  local name normalized url http body body_file rc member
  name="$(bash "${SCRIPT_DIR}/sdist-meta.sh" "$ARCHIVE" name)" || {
    echo "HINWEIS: Paketname nicht lesbar - Vorabpruefung uebersprungen" >&2
    return 1
  }
  normalized="$(normalize_name "$name")"
  url="${BASE}/repository/${NEXUS_PYPI_HOSTED}/simple/${normalized}/"

  body_file="$(mktemp)"
  set +e
  http="$(cfg_credentials \
          | curl --config - --silent --show-error \
                 --output "$body_file" --write-out '%{http_code}' \
                 "$url" 2>/dev/null)"
  rc=$?
  set -e
  body="$(cat "$body_file")"
  rm -f "$body_file"

  if [[ $rc -ne 0 ]]; then
    echo "HINWEIS: Simple-Index nicht abfragbar (curl-Exit ${rc}) - Vorabpruefung uebersprungen" >&2
    return 1
  fi
  case "$http" in
    200) : ;;
    404) return 1 ;;
    *)   echo "HINWEIS: Simple-Index lieferte HTTP ${http} - Vorabpruefung uebersprungen" >&2
         return 1 ;;
  esac

  # Link-Texte aus dem Index ziehen und EXAKT vergleichen. Ein Substring-Test
  # wuerde '<datei>' faelschlich in einem gelisteten '<datei>.asc' finden.
  member="$(basename "$ARCHIVE")"
  tr '<' '\n' <<<"$body" | sed -n 's/^[aA] [^>]*>//p' | grep -qxF "$member"
}

if already_published; then
  echo "SKIP: $(basename "$ARCHIVE") liegt bereits in ${NEXUS_PYPI_HOSTED}"
  exit 0
fi
```

(c) Im 400-Zweig den Duplikat-Fall von Fehler auf Skip umstellen. Ersetze

```bash
    if grep -qiE 'already exists|does not allow updating' <<<"$BODY"; then
      echo "FEHLER: Version liegt bereits im Repo. Version im Paket erhoehen." >&2
      exit 2
    fi
```

durch

```bash
    # Die Vorabpruefung hat das Duplikat nicht gesehen (Index nicht abfragbar,
    # oder ein zweiter Build war schneller). Ergebnis ist dasselbe: die Datei
    # liegt im Repo, es gibt nichts zu tun.
    if grep -qiE 'already exists|does not allow updating' <<<"$BODY"; then
      echo "SKIP: $(basename "$ARCHIVE") liegt bereits in ${NEXUS_PYPI_HOSTED} (Nexus meldete HTTP 400)"
      exit 0
    fi
```

(d) Den Kopfkommentar des Skripts um zwei Saetze ergaenzen: dass vor dem Upload der Simple-Index gefragt wird, und dass ein Duplikat uebersprungen statt abgelehnt wird.

- [ ] **Step 6: Tests laufen lassen — gruen**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh 2>&1 | tail -2; bash test/run-tests.sh >/dev/null 2>&1; echo "Exit: $?"
```

Erwartet: FAIL 0, Exit 0.

- [ ] **Step 7: Gegenproben**

Nach jeder Mutation mit `cmp` gegen die Sicherung bestaetigen, dass sie geschrieben hat; danach zuruecksetzen.

```bash
cd /Users/bengoo/projects/jenkins
S=resources/de/firma/ci/publish-pypi.sh; BAK="$(mktemp)"; cp $S "$BAK"
probe() { printf '%-44s ' "$1"; cmp -s $S "$BAK" && { echo "NICHT ANGEWENDET"; return; }
  bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL-Zeilen: %s\n'; cp "$BAK" $S; }

# (a) Vorabpruefung ausbauen -> Skip-Faelle rot
python3 -c 'import io,re;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();s=re.sub(r"if already_published; then.*?\nfi\n","",s,flags=re.S);io.open(p,"w").write(s)'
probe "(a) already_published nicht aufgerufen"

# (b) Substring statt exaktem Vergleich -> .asc-Fall rot
python3 -c 'import io;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("grep -qxF \"$member\"","grep -qF \"$member\""))'
probe "(b) Substring statt exakt"

# (c) Normalisierung weg -> URL-Assertion rot
python3 -c 'import io;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("normalized=\"$(normalize_name \"$name\")\"","normalized=\"$name\""))'
probe "(c) ohne PEP-503-Normalisierung"

# (d) Index-Fehler soll haerter sein -> 401/curl-Faelle rot
python3 -c 'import io;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("    *)   echo \"HINWEIS: Simple-Index lieferte HTTP ${http} - Vorabpruefung uebersprungen\" >&2\n         return 1 ;;","    *)   exit 1 ;;"))'
probe "(d) Index-Fehler bricht ab statt zu warnen"

# (e) 400-Pfad zurueck auf Fehler -> Duplikat-Faelle rot
python3 -c 'import io;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("exit 0\n    fi","exit 2\n    fi",1))'
probe "(e) 400-Duplikat wieder als Fehler"

cp "$BAK" $S; rm "$BAK"; git status --short; echo "(leer = wiederhergestellt)"
```

Erwartet: jede Zeile meldet mindestens eine FAIL-Zeile. Bleibt eine angewendete Mutation gruen, ist das ein Befund — melden, nicht die Mutation anpassen.

- [ ] **Step 8: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add resources/de/firma/ci/publish-pypi.sh test/run-tests.sh
git commit -m "$(cat <<'EOF'
publish-pypi.sh: Upload ueberspringen, wenn die Datei schon im Repo liegt

Vor dem Upload wird der Simple-Index des Ziel-Repos gefragt (PEP 503, die
API die auch pip liest). Ist der Dateiname dort exakt gelistet, entfaellt
der Upload und das Skript endet mit Exit 0 und einer SKIP-Meldung.
Verglichen wird exakt, nicht als Substring - sonst faende sich
<datei> faelschlich in einem gelisteten <datei>.asc.

Die Pruefung ist eine Abkuerzung, kein Gate: laesst sich der Index nicht
abfragen, wird gewarnt und normal hochgeladen. Der 400-Pfad faengt ein
Duplikat dann trotzdem ab und ueberspringt jetzt ebenfalls, statt mit
Exit 2 abzulehnen. Exit 2 kommt damit nicht mehr vor.

Folge, bewusst in Kauf genommen: ein vergessener Version-Bump faellt
nicht mehr auf, der Build bleibt gruen.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Dokumentation nachziehen

**Files:**
- Modify: `README-ci.md`
- Modify: `docs/superpowers/specs/2026-09-03-publish-ohne-twine-design.md`

**Interfaces:**
- Consumes: das Verhalten aus Task 1 (Skip-Faelle, Exit-Codes).
- Produces: nichts fuer spaetere Tasks.

- [ ] **Step 1: README-Abschnitt "Doppelte Versionen" neu schreiben**

Der Abschnitt beschreibt heute Exit 2 als Schutz vor vergessenem Version-Bump. Ersetze ihn durch:

```markdown
## Doppelte Versionen

Wird dieselbe Version erneut gebaut - ein Re-Run, oder ein Monorepo-Build, in
dem sich nur eines von mehreren Paketen geaendert hat -, laedt
`publish-pypi.sh` nicht erneut hoch. Vor dem Upload fragt es den Simple-Index
des Ziel-Repos (`/repository/<repo>/simple/<name>/`, dieselbe API, die auch pip
liest). Ist der Dateiname dort gelistet, meldet das Skript

    SKIP: mein_paket-1.2.3.tar.gz liegt bereits in pypi-hosted

und endet mit Exit-Code 0. Verglichen wird der exakte Dateiname, nicht als
Teilzeichenkette - sonst wuerde ein gelistetes `...tar.gz.asc` faelschlich als
Treffer zaehlen.

Die Pruefung ist eine Abkuerzung, kein Gate. Laesst sich der Index nicht
abfragen - fehlende Rechte, unerwarteter Status, curl scheitert -, wird nur
gewarnt und normal hochgeladen. Lehnt Nexus den Upload dann mit HTTP 400 und
`already exists` bzw. `does not allow updating` ab, gilt dasselbe: Datei liegt
im Repo, Exit-Code 0, `SKIP`-Meldung. Das deckt auch den Fall ab, dass zwei
Builds gleichzeitig dieselbe Version hochladen wollen.

**Damit faellt ein vergessener Version-Bump nicht mehr auf.** Der Build wird
gruen, im Repo bleibt die alte Version liegen. Das ist der Preis dafuer, dass
ein Re-Run keinen roten Build erzeugt; wer den Bump erzwingen will, prueft die
Version im Merge-Request statt im Build.
```

- [ ] **Step 2: Exit-Code-Liste im README pruefen und nachziehen**

```bash
cd /Users/bengoo/projects/jenkins
grep -n 'Exit-Code 2\|Exit 2\|exit 2' README-ci.md
```

Jede Fundstelle, die Exit 2 als Ergebnis von `publish-pypi.sh` beschreibt, entfernen oder umschreiben — es gibt ihn nicht mehr. Exit 3 (falscher Repo-Typ) und `SKIP_REPO_CHECK=1` bleiben unveraendert.

- [ ] **Step 3: Nachtrag in der Vorgaenger-Spec**

An `docs/superpowers/specs/2026-09-03-publish-ohne-twine-design.md` anhaengen:

```markdown
## Nachtrag 2026-09-03: Duplikate werden uebersprungen, Exit 2 entfaellt

Die Statuszuordnung oben nennt fuer HTTP 400 mit `already exists` bzw.
`does not allow updating` den Exit-Code 2. Das ist ersetzt: seit der
Vorabpruefung ueber den Simple-Index gilt ein Duplikat als "nichts zu tun" und
endet mit Exit 0 und einer `SKIP`-Meldung - sowohl wenn die Vorabpruefung es
findet als auch wenn erst Nexus mit 400 antwortet. Exit-Code 2 kommt im Skript
nicht mehr vor. Details: `2026-09-03-publish-skip-wenn-vorhanden-design.md`.
```

- [ ] **Step 4: Gegenpruefen**

```bash
cd /Users/bengoo/projects/jenkins
echo "--- Exit 2 noch irgendwo behauptet? (docs/ ohne die historischen Plaene) ---"
grep -rn 'Exit-Code 2\|Exit 2' README-ci.md docs/superpowers/specs/ || echo "keine"
echo "--- nennt das README die Skip-Meldung? ---"
grep -n 'SKIP:' README-ci.md
echo "--- Tests weiterhin gruen ---"
bash test/run-tests.sh 2>&1 | tail -1
```

Erwartet: Exit 2 wird nirgends mehr als Ergebnis beschrieben (Treffer im Nachtrag, der ihn als *ersetzt* bezeichnet, sind in Ordnung); das README nennt die `SKIP:`-Meldung; FAIL 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add README-ci.md docs/superpowers/specs/2026-09-03-publish-ohne-twine-design.md
git commit -m "$(cat <<'EOF'
README und Vorgaenger-Spec: Duplikate werden uebersprungen

Der Abschnitt "Doppelte Versionen" beschrieb Exit 2 als Schutz vor
vergessenem Version-Bump. Beschrieben ist jetzt die Vorabpruefung ueber
den Simple-Index, die SKIP-Meldung und Exit 0 - inklusive des ehrlichen
Hinweises, dass ein vergessener Version-Bump dadurch nicht mehr auffaellt.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Nach dem Plan

Beim ersten echten Lauf gegen ein Nexus in dieser Reihenfolge pruefen:

1. Ein Paket zweimal hintereinander bauen. Der zweite Lauf muss die
   `SKIP:`-Zeile zeigen und darf keinen Upload-Aufruf machen.
2. Bleibt die `SKIP:`-Zeile aus und stattdessen erscheint sie erst nach dem
   Upload (`Nexus meldete HTTP 400`), liefert der Simple-Index nicht das
   erwartete Format - dann im Log den Hinweis `Vorabpruefung uebersprungen`
   suchen und die tatsaechliche Index-Antwort ansehen.
3. Ein Paket mit Grossbuchstaben oder Punkt im Namen bauen und pruefen, dass
   die Index-URL den normalisierten Namen nutzt.

---

## Nachtrag 2026-09-03: Ergebnis der Ausfuehrung

Beide Tasks umgesetzt, je Task Review und Fix-Runde; Abschluss-Review ueber den
gesamten Bereich (0 Critical, 2 Important, 9 Minor, "With fixes"), eine
Fix-Welle und ein scoped Re-Review, beide sauber. Testtreiber am Ende:
PASS 280 FAIL 0 SKIP 3 (vorher 237).

Zwei Dinge, die der Plan nicht vorhergesehen hat und die beide in die
gefaehrliche Richtung zeigten:

* **Falscher Skip durch die Kopplung zweier beratender Pruefungen.** Zeigt
  `NEXUS_PYPI_HOSTED` auf ein Group-Repo UND ist die Repositories-REST-API
  nicht erreichbar - jede Situation fuer sich bewusst toleriert -, aggregiert
  der Simple-Index der Group ihre Member. Ein Treffer aus dem PyPI-Proxy loeste
  den Skip aus: gruener Build, nichts publiziert. Vorher wurde dieselbe
  Fehlkonfiguration rot. Behoben, indem die Abkuerzung nur noch genommen wird,
  wenn `check_repo_type` `hosted pypi` bestaetigt hat; `SKIP_REPO_CHECK=1`
  zaehlt als "nicht bestaetigt". Das war eine Luecke der Spec, nicht der
  Umsetzung: zwei unabhaengig als "darf scheitern" entworfene Pruefungen
  ergaben zusammen ein Gate.
* **SIGPIPE unter `pipefail`** in der Link-Extraktion: `grep -q` schliesst beim
  Treffer die Pipe, `sed` stirbt, der Pipeline-Status wird 141 und der Skip
  verpuffte lautlos. Reproduziert: ab ~36 KB Index. Behoben nach der
  Hauskonvention aus `sdist-meta.sh` - erst vollstaendig in eine Variable,
  dann Herestring. Derselbe Fehler war in diesem Projekt schon zweimal
  behoben worden; der Plan hat ihn trotzdem wieder eingefuehrt.

Ausserdem: `--connect-timeout 10 --max-time 30` an der Index-Abfrage (sie liegt
auf dem kritischen Pfad jedes `publish()` und darf den Build nicht aufhalten;
der Upload selbst bleibt ohne Zeitlimit).

### Bewusst zurueckgestellt — nach dem Merge

* Kein Dauertest fuer die Reihenfolge der Stub-URL-Muster; ein Rueckbau faellt
  der Suite nicht auf.
* `RC=$?` nach `cfg_credentials | curl` ist unter `pipefail` der Pipeline-Status
  - vom Abschluss-Review als praktisch unerreichbar nachgewiesen, weil curl die
  kurze Config immer vollstaendig liest.
* Der curl-Stub haengt bei einer offenen, nie schliessenden Pipe ohne TTY.
* `printf '%s\n' "$BODY"` gibt bei leerem Body eine Leerzeile aus.
* Die README-Aussage zum von Nexus vergebenen Ablagepfad ist unbelegbar.

### Erster echter Lauf gegen ein Nexus — Pruefreihenfolge

1. Dasselbe Paket zweimal bauen. Der zweite Lauf muss `SKIP:` zeigen und
   **keinen** Upload-Aufruf machen.
2. Erscheint stattdessen `HINWEIS: Repo-Typ nicht bestaetigt`, liefert die
   Repositories-REST-API nicht `hosted`/`pypi` fuer euer Repo - dann greift die
   Abkuerzung nie, und der 400-Pfad uebernimmt.
3. Erscheint `Vorabpruefung uebersprungen` mit einem HTTP-Status, liefert der
   Simple-Index nicht das erwartete Format; die tatsaechliche Antwort ansehen.
4. Ein Paket mit Grossbuchstaben oder Punkt im Namen bauen und pruefen, dass
   die Index-URL den PEP-503-normalisierten Namen nutzt.
5. Ein Paket mit vielen Versionen (grosser Index) - der Skip muss auch dort
   greifen.
