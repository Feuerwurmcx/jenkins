# publish-pypi.sh ohne twine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `publish-pypi.sh` laedt die sdist per `curl` gegen die Nexus-REST-Components-API hoch statt per `python3 -m twine upload`, weil auf dem Agent kein twine verfuegbar ist und Nachinstallieren ausgeschlossen ist.

**Architecture:** Ein `curl`-POST auf `/service/rest/v1/components?repository=<repo>` mit `-F pypi.asset=@<archiv>`. Der HTTP-Status kommt per `--write-out` getrennt vom Body (`--output` in eine Temp-Datei); daraus wird der Exit-Grund abgeleitet statt aus Fliesstext. Zugangsdaten weiterhin per `curl --config -` von stdin, jetzt mit Escaping. Getestet wird mit einem `curl`-Stub im PATH, analog zum vorhandenen `python3`-Stub.

**Tech Stack:** Bash (bash 3.2 tauglich), `curl`, `python3` (nur fuer das JSON des Repo-Typ-Checks), Nexus 3 REST API.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-03-publish-ohne-twine-design.md`. Exit-Codes, Statuszuordnung und Meldungstexte exakt von dort.
- Umfang: **nur** `resources/de/firma/ci/publish-pypi.sh`, `test/run-tests.sh` und Doku. `build-sdist.sh`, `sdist-meta.sh`, `changed-packages.sh`, `vars/pyMonorepo.groovy` und `examples/` werden **nicht** angefasst.
- Exit-Codes unveraendert: 2 = Version existiert bereits, 3 = falscher Repo-Typ, 1 = sonstiger Fehler.
- `set -euo pipefail` und `set +x` bleiben. Fehlermeldungen nach stderr, Nutzdaten nach stdout.
- Zugangsdaten gehen NIE ueber argv — nur ueber `curl --config -` von stdin.
- Kommentare und Meldungen auf Deutsch, im Stil des Bestands.
- macOS, `/bin/bash` 3.2, BSD sed/grep: `sed -i ''`, `[[:space:]]` statt `\s`, kein `mapfile`, keine assoziativen Arrays.
- Jeder neue Test braucht einen gezeigten Rotlauf (Fix zuruecknehmen, rot, wiederherstellen).
- Am Ende: `bash test/run-tests.sh` FAIL 0, Exit 0; `git status --short` leer.
- Commit-Betreff ohne Umlaute, Message auf Deutsch, endend mit `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

| Datei | Verantwortung |
|---|---|
| `resources/de/firma/ci/publish-pypi.sh` | Repo-Typ-Check (unveraendert) + Upload per curl; `cfg_escape`/`cfg_credentials` als gemeinsame Credential-Quelle beider curl-Aufrufe |
| `test/run-tests.sh` | `make_curl_stub()` + neuer Block `=== publish-pypi.sh Upload (curl-Stub) ===`; der bestehende Guard-Clause-Block bleibt |
| `README-ci.md` | Voraussetzungen, Zugangsdaten-Abschnitt, Abschnitt zu doppelten Versionen |
| `docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md` | der twine-Satz im Ursprungsdesign |

---

## Task 1: Upload auf curl umstellen, mit Stub-Tests

**Files:**
- Modify: `test/run-tests.sh` (neue Funktion `make_curl_stub`, neuer Testblock)
- Modify: `resources/de/firma/ci/publish-pypi.sh`

**Interfaces:**
- Consumes: `assert_rc`, `assert_contains`, `assert_eq`, `ok`, `nok`, `skip`, `$SCRIPTS`, `$TMP`, `$ARCHIVE` (im Treiber bereits gesetzt, ein per `make_sdist` gebautes Archiv) aus `test/run-tests.sh`.
- Produces: `bash publish-pypi.sh <archiv>` mit unveraenderter Signatur; Exit 0 bei 201/204, 2 bei HTTP 400 mit "already exists"/"does not allow updating", 3 bei falschem Repo-Typ, sonst 1. Neu im Skript: `cfg_escape` und `cfg_credentials` (beide privat, kein anderes Skript ruft sie).

- [ ] **Step 1: curl-Stub und Tests einfuegen**

Fuege in `test/run-tests.sh` direkt hinter der Funktion `make_python_stub` (sie endet mit der Zeile, die das Stub-Verzeichnis auf stdout ausgibt) diese Funktion ein:

```bash
# curl-Stub: kein echtes curl. Schreibt Argumente und stdin mit, damit die Tests
# pruefen koennen, dass die Zugangsdaten NICHT in argv stehen, und antwortet mit
# einem per Umgebung gesteuerten HTTP-Status.
#   STUB_DIR        Verzeichnis fuer curl-args / curl-stdin (Pflicht)
#   STUB_HTTP       HTTP-Status, den der Upload-Aufruf meldet (Default 204)
#   STUB_BODY       Body, den der Upload-Aufruf in die --output-Datei schreibt
#   STUB_CURL_RC    Exit-Code des Stubs (Default 0) - simuliert Netzfehler
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
for a in "$@"; do
  if [[ "$prev" == "--output" ]]; then out="$a"; fi
  prev="$a"
done

if [[ -z "$out" ]]; then
  # Repo-Typ-Check
  printf '%s' "${STUB_REPOS_JSON:-[]}"
  exit 0
fi

printf '%s' "${STUB_BODY:-}" > "$out"
printf '%s' "${STUB_HTTP:-204}"
exit "${STUB_CURL_RC:-0}"
STUB
  chmod +x "${d}/curl"
  printf '%s\n' "$d"
}
```

Fuege danach, direkt vor `echo "=== Bilanz ==="`, den neuen Testblock ein:

```bash
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
  "pypi.asset=@${ARCHIVE}"
assert_contains "POST wird verwendet" "$PUB_ARGS" "POST"

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

run_publish notfound NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=404
assert_rc "404 -> rc 1" 1 "$PUB_RC"
assert_contains "404 -> Meldung nennt das Repository" "$PUB_OUT" "pypi-hosted"

run_publish weird NEXUS_USER=u NEXUS_PASS=p STUB_HTTP=500 STUB_BODY='Internal Server Error'
assert_rc "500 -> rc 1" 1 "$PUB_RC"
assert_contains "500 -> Status erscheint" "$PUB_OUT" "500"

run_publish netz NEXUS_USER=u NEXUS_PASS=p STUB_CURL_RC=7
if [[ $PUB_RC -ne 0 ]]; then ok "curl-Fehler -> rc != 0"
else nok "curl-Fehler -> rc != 0" "rc=0"; fi
assert_contains "curl-Fehler -> Meldung nennt curl" "$PUB_OUT" "curl"

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

skip "publish-pypi.sh echter Netzwerk-Upload" "braucht ein erreichbares Nexus - bewusst nicht getestet"
```

- [ ] **Step 2: Tests laufen lassen — sie muessen rot sein**

```bash
bash test/run-tests.sh 2>&1 | sed -n '/publish-pypi.sh Upload/,/Bilanz/p'; echo "Exit: ${PIPESTATUS[0]}"
```

Erwartet: Exit 1. Das heutige Skript ruft `python3 -m twine upload`, der Stub wird also nie aufgerufen — `curl-args` und `curl-stdin` bleiben leer. Damit schlagen alle Assertions auf `$PUB_ARGS`/`$PUB_STDIN` fehl (URL, Formularfeld, POST, Passwort-in-stdin, beide Escaping-Faelle), ebenso `204 -> rc 0`, `201 -> rc 0` und die beiden rc-2-Faelle.

**Fuenf Faelle sind schon vor der Umstellung gruen, und das ist kein Testfehler:** `400 mit anderem Body -> rc 1`, `401 -> rc 1`, `404 -> rc 1`, `500 -> rc 1` und `curl-Fehler -> rc != 0` erwarten einen Fehlschlag — und das heutige Skript scheitert mangels twine ohnehin mit rc 1. Sie beweisen erst nach Step 3 etwas, gemeinsam mit ihren `assert_contains`-Nachbarn auf den Meldungstext, die jetzt rot sind.

Halte im Report fest, welche Assertions rot waren. Ist eine der oben als rot erwarteten gruen, pruef sie einzeln, statt sie stehenzulassen.

- [ ] **Step 3: publish-pypi.sh umbauen**

Ersetze `resources/de/firma/ci/publish-pypi.sh` vollstaendig durch:

```bash
#!/usr/bin/env bash
# Lädt eine sdist in ein Nexus PyPI-HOSTED-Repository (REST-Components-API).
#
#   NEXUS_URL=https://nexus.example.com NEXUS_PYPI_HOSTED=pypi-internal \
#   NEXUS_USER=... NEXUS_PASS=... publish-pypi.sh <archiv>
#
# Zum LESEN nimmt man das Group-Repo (z.B. group_pypi), zum SCHREIBEN nie:
# ein Group-Repo aggregiert nur, es nimmt keine Uploads an.
#
# Kein twine: auf dem Agent ist es nicht verfügbar und Nachinstallieren ist
# ausgeschlossen. Hochgeladen wird per curl gegen /service/rest/v1/components –
# ein Aufruf, und anders als beim Legacy-Weg (:action=file_upload) müssen Name,
# Version und filetype nicht als eigene Formularfelder mitgeschickt werden.
#
# Zugangsdaten gehen über 'curl --config -' von stdin, nicht über argv: sonst
# stünden sie in der Prozessliste jedes Nutzers auf dem Agent.
set -euo pipefail
set +x

ARCHIVE="${1:?archiv fehlt}"

: "${NEXUS_URL:?NEXUS_URL fehlt}"
: "${NEXUS_PYPI_HOSTED:?NEXUS_PYPI_HOSTED fehlt (HOSTED-Repo, nicht die Group!)}"
: "${NEXUS_USER:?NEXUS_USER fehlt}"
: "${NEXUS_PASS:?NEXUS_PASS fehlt}"

[[ -f "$ARCHIVE" ]] || { echo "FEHLER: $ARCHIVE nicht gefunden" >&2; exit 1; }

BASE="${NEXUS_URL%/}"
UPLOAD_URL="${BASE}/service/rest/v1/components?repository=${NEXUS_PYPI_HOSTED}"

# --- Zugangsdaten ------------------------------------------------------------
# Im curl-Config-Format sind " und \ Sonderzeichen. Ohne Escaping bricht ein
# Passwort mit Anführungszeichen den Aufruf – beim Repo-Check still (er
# degradiert zur Warnung), beim Upload laut.
cfg_escape() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }

cfg_credentials() {
  printf 'user = "%s:%s"\n' "$(cfg_escape "$NEXUS_USER")" "$(cfg_escape "$NEXUS_PASS")"
}

# --- Schutz vor dem Klassiker: Upload gegen ein Group-Repo -------------------
# Die REST-API sagt uns den Typ. Ist sie nicht erreichbar (fehlende Rechte),
# wird nur gewarnt statt abzubrechen.
check_repo_type() {
  local json type
  json=$(cfg_credentials \
         | curl --config - --silent --fail \
                "${BASE}/service/rest/v1/repositories" 2>/dev/null) || {
    echo "HINWEIS: Repo-Typ nicht prüfbar (REST-API nicht erreichbar/keine Rechte)" >&2
    return 0
  }
  type=$(python3 -c '
import json,sys
name=sys.argv[1]
for r in json.load(sys.stdin):
    if r.get("name")==name:
        print(r.get("type",""), r.get("format",""))
        break
' "$NEXUS_PYPI_HOSTED" <<<"$json")
  case "$type" in
    "group "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist ein GROUP-Repo. Group-Repos nehmen" >&2
      echo "        keine Uploads an – NEXUS_PYPI_HOSTED auf das hosted-Repo" >&2
      echo "        setzen, das Mitglied der Group ist." >&2
      exit 3 ;;
    "proxy "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist ein PROXY-Repo, kein hosted." >&2
      exit 3 ;;
    "hosted pypi") : ;;
    "hosted "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist hosted, aber kein PyPI-Format (${type})." >&2
      exit 3 ;;
    *) echo "HINWEIS: Repo '${NEXUS_PYPI_HOSTED}' in der API nicht gefunden" >&2 ;;
  esac
}
[[ "${SKIP_REPO_CHECK:-0}" == "1" ]] || check_repo_type

# --- Upload -----------------------------------------------------------------
echo "Upload -> ${UPLOAD_URL}  ($(basename "$ARCHIVE"))"

BODY_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$ERR_FILE"' EXIT

# Status per --write-out getrennt vom Body: so steht der Exit-Grund fest, statt
# aus dem Fließtext der Antwort geraten zu werden.
set +e
HTTP="$(cfg_credentials \
        | curl --config - --silent --show-error \
               --output "$BODY_FILE" --write-out '%{http_code}' \
               --request POST \
               --form "pypi.asset=@${ARCHIVE}" \
               "$UPLOAD_URL" 2>"$ERR_FILE")"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  echo "FEHLER: curl scheiterte (Exit ${RC}) – Nexus nicht erreichbar?" >&2
  cat "$ERR_FILE" >&2
  exit "$RC"
fi

BODY="$(cat "$BODY_FILE")"

case "$HTTP" in
  201|204)
    echo "OK: $(basename "$ARCHIVE")" ;;
  400)
    # Ein PyPI-hosted-Repo lehnt eine bereits vorhandene Version ab – das ist
    # fast immer ein vergessener Version-Bump, kein Infrastrukturfehler.
    if grep -qiE 'already exists|does not allow updating' <<<"$BODY"; then
      echo "FEHLER: Version liegt bereits im Repo. Version im Paket erhoehen." >&2
      exit 2
    fi
    echo "FEHLER: Upload abgelehnt (HTTP 400)" >&2
    printf '%s\n' "$BODY" >&2
    exit 1 ;;
  401|403)
    echo "FEHLER: Zugangsdaten abgelehnt oder keine Deploy-Rechte auf '${NEXUS_PYPI_HOSTED}' (HTTP ${HTTP})" >&2
    exit 1 ;;
  404)
    echo "FEHLER: Repository '${NEXUS_PYPI_HOSTED}' existiert nicht unter ${BASE} (HTTP 404)" >&2
    exit 1 ;;
  *)
    echo "FEHLER: unerwarteter HTTP-Status ${HTTP} beim Upload" >&2
    printf '%s\n' "$BODY" >&2
    exit 1 ;;
esac
```

- [ ] **Step 4: Tests laufen lassen — jetzt gruen**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh 2>&1 | tail -3; echo "Exit: ${PIPESTATUS[0]}"
```

Erwartet: FAIL 0, Exit 0. Die SKIP-Zahl steigt um 1 (der echte Netzwerk-Upload), die alte SKIP-Zeile `publish-pypi.sh echter Upload` ist durch `publish-pypi.sh echter Netzwerk-Upload` ersetzt.

- [ ] **Step 5: Gegenproben — jede neue Zusage einzeln brechen**

Nach jeder Mutation mit `git diff --stat` pruefen, dass sie wirklich geschrieben hat; danach aus der Sicherung wiederherstellen.

```bash
cd /Users/bengoo/projects/jenkins
S=resources/de/firma/ci/publish-pypi.sh; BAK="$(mktemp)"; cp $S "$BAK"
probe() { printf '%-46s ' "$1"; git diff --stat -- $S | grep -q changed \
  || { echo "NICHT ANGEWENDET"; cp "$BAK" $S; return; }
  bash test/run-tests.sh 2>&1 | grep -cE '^FAIL' | xargs printf 'FAIL-Zeilen: %s\n'; cp "$BAK" $S; }

# (a) Zugangsdaten in argv statt stdin -> "Passwort steht NICHT in argv" muss rot.
#     python3 -c statt sed: das Muster enthaelt eine Pipe (sed-Delimiter) und
#     ein $, beides macht einen sed-Einzeiler hier falsch oder unlesbar.
python3 -c 'import io;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();io.open(p,"w").write(s.replace("--config - --silent --show-error","--user u:s3cr3t-nicht-in-argv --silent --show-error"))'
probe "(a) Credentials in argv"

# (b) Escaping entfernt -> die zwei Escaping-Assertions muessen rot
python3 -c 'import io;p="resources/de/firma/ci/publish-pypi.sh";s=io.open(p).read();s=s.replace("$(cfg_escape \"$NEXUS_USER\")","$NEXUS_USER").replace("$(cfg_escape \"$NEXUS_PASS\")","$NEXUS_PASS");io.open(p,"w").write(s)'
probe "(b) cfg_escape wird nicht mehr benutzt"

# (c) 400-Erkennung abgeschaltet -> rc-2-Faelle muessen rot
sed -i '' "s|if grep -qiE 'already exists|if grep -qiE 'niemalsniemals|" $S
probe "(c) 400-Erkennung abgeschaltet"

# (d) falscher Endpunkt -> URL-Assertion muss rot
sed -i '' 's|/service/rest/v1/components?repository=|/repository/|' $S
probe "(d) falscher Upload-Endpunkt"

# (e) Formularfeld falsch benannt -> pypi.asset-Assertion muss rot
sed -i '' 's|pypi.asset=@|asset=@|' $S
probe "(e) Formularfeld heisst nicht pypi.asset"

cp "$BAK" $S; rm "$BAK"; git status --short; echo "(leer = wiederhergestellt)"
```

Erwartet: jede Zeile meldet mindestens eine FAIL-Zeile; am Ende ist der Arbeitsbaum sauber. Falls eine Mutation `NICHT ANGEWENDET` meldet, ist das `sed` fuer BSD anzupassen — die Probe zaehlt sonst nicht.

- [ ] **Step 6: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add resources/de/firma/ci/publish-pypi.sh test/run-tests.sh
git commit -m "$(cat <<'EOF'
publish-pypi.sh: Upload ohne twine ueber die Nexus-Components-API

Auf dem Agent ist twine nicht verfuegbar und Nachinstallieren ausgeschlossen.
Hochgeladen wird jetzt per curl gegen /service/rest/v1/components; der
HTTP-Status kommt per --write-out getrennt vom Body, dadurch steht der
Exit-Grund fest statt aus Fliesstext geraten zu werden.

Nimmt zwei zurueckgestellte Befunde mit: die Zugangsdaten werden fuer die
curl-Config escaped (" und \ sind dort Steuerzeichen), und die Erkennung
doppelter Versionen haengt nicht mehr an einem grep nach "400", das auch in
einem Dateinamen wie foo-1.400.tar.gz zutraf.

Ein curl-Stub im Testtreiber deckt die Statusfaelle, den Endpunkt und das
Formularfeld ab - und prueft erstmals maschinell, dass das Passwort in der
curl-Config auf stdin landet und nicht in argv.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Dokumentation nachziehen

**Files:**
- Modify: `README-ci.md`
- Modify: `docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md`
- Modify: `resources/de/firma/ci/build-sdist.sh` ist **nicht** betroffen — nicht anfassen.

**Interfaces:**
- Consumes: das Verhalten aus Task 1 (Exit-Codes, Endpunkt, Credential-Weg).
- Produces: nichts fuer spaetere Tasks.

- [ ] **Step 1: Voraussetzungen im README korrigieren**

Im Abschnitt "Voraussetzungen auf dem Agent" steht `twine` in der Werkzeugliste. Entferne es und ergaenze den Grund, damit niemand es versehentlich wieder aufnimmt:

```bash
cd /Users/bengoo/projects/jenkins
grep -n 'twine' README-ci.md
```

Ersetze die Nennung von `twine` in der Aufzaehlung so, dass dort `bash`, `git`, `tar`, `curl` und `python3` (mit `build` oder `setuptools`) stehen, und haenge an den Abschnitt einen Satz an:

```
Ausdruecklich **nicht** noetig ist `twine`: der Upload laeuft per `curl` gegen
die Nexus-REST-Components-API.
```

- [ ] **Step 2: Zugangsdaten-Abschnitt korrigieren**

Der Abschnitt "Umgang mit den Zugangsdaten" nennt in Punkt 3 `TWINE_USERNAME`/`TWINE_PASSWORD`. Ersetze diesen Punkt durch:

```
**3. argv.** Beide `curl`-Aufrufe in `publish-pypi.sh` – der Repo-Typ-Check und
der Upload – lesen die Zugangsdaten ueber `curl --config -` von stdin, nicht als
Kommandozeilenargument: sonst stuenden sie in der Prozessliste jedes Nutzers auf
dem Agent. `"` und `\` werden dabei escaped, weil sie im curl-Config-Format
Steuerzeichen sind. Der Testtreiber prueft beides.
```

- [ ] **Step 3: Abschnitt zu doppelten Versionen korrigieren**

Dort steht heute, dass `publish-pypi.sh` den 400-Fall an der Ausgabe von twine erkennt. Ersetze die Begruendung durch:

```
Ein PyPI-hosted-Repo lehnt eine bereits vorhandene Version mit HTTP 400 ab;
`publish-pypi.sh` wertet den Statuscode getrennt vom Antwort-Body aus und
bricht dann mit Exit-Code 2 und klarer Meldung ab. Andere 400er werden mit
Status und Body ausgegeben und enden mit Exit-Code 1.
```

Pruef dabei, dass die uebrigen Exit-Code-Aussagen im README weiterhin stimmen (2 = Version existiert, 3 = falscher Repo-Typ inkl. der drei Faelle group/proxy/hosted-nicht-pypi, `SKIP_REPO_CHECK=1`).

- [ ] **Step 4: Ursprungs-Spec nachziehen**

`docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md` beschreibt `publish-pypi.sh` als twine-Upload. Ergaenze am Ende der Datei einen datierten Nachtrag:

```
## Nachtrag 2026-09-03: Upload ohne twine

Auf dem Ziel-Agent ist `twine` nicht verfuegbar und Nachinstallieren ist
ausgeschlossen. `publish-pypi.sh` laedt deshalb per `curl` gegen
`/service/rest/v1/components?repository=<repo>` hoch statt per
`python3 -m twine upload`. Aufrufsignatur, Exit-Codes (2 = Version existiert,
3 = falscher Repo-Typ) und der Repo-Typ-Check bleiben unveraendert. Details:
`2026-09-03-publish-ohne-twine-design.md`.
```

- [ ] **Step 5: Gegenpruefen, dass keine twine-Reste bleiben**

```bash
cd /Users/bengoo/projects/jenkins
echo "--- twine ausserhalb von docs/ (erwartet: keine) ---"
grep -rn --exclude-dir=.git --exclude-dir=docs --exclude-dir=.superpowers -i 'twine' . || echo "keine"
echo "--- twine in docs/ (nur historische Nennungen + Nachtraege) ---"
grep -rn -i 'twine' docs/ | cut -c1-100
echo "--- Werkzeugliste im README gegen die tatsaechlichen Aufrufe ---"
grep -ohE '\b(curl|python3|git|tar)\b' resources/de/firma/ci/*.sh | sort -u
```

Erwartet: kein twine ausserhalb von `docs/`; die Werkzeugliste im README nennt genau die tatsaechlich aufgerufenen Kommandos.

- [ ] **Step 6: Tests und Commit**

```bash
cd /Users/bengoo/projects/jenkins
bash test/run-tests.sh 2>&1 | tail -2
git add README-ci.md docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md
git commit -m "$(cat <<'EOF'
README und Ursprungs-Spec: twine raus, curl rein

Die Voraussetzungen nannten twine, der Zugangsdaten-Abschnitt
TWINE_USERNAME/TWINE_PASSWORD und die Begruendung fuer Exit-Code 2 die
twine-Ausgabe. Alle drei beschreiben jetzt den curl-Weg ueber die
Components-API und den getrennt ausgewerteten HTTP-Status.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Nach dem Plan

Beim ersten echten Lauf gegen ein Test-Repo in dieser Reihenfolge pruefen:

1. Ein Upload einer neuen Version -> erwartet HTTP 204 und `OK: <datei>`. Sollte
   Nexus einen anderen Erfolgsstatus liefern, faellt das sofort in den
   `*`-Zweig und wird mit Status und Body ausgegeben.
2. Denselben Upload wiederholen -> erwartet Exit 2 mit dem Version-Bump-Hinweis.
   Trifft der Text der 400-Antwort weder `already exists` noch
   `does not allow updating`, landet der Fall im generischen 400-Zweig; dann
   den tatsaechlichen Body ins Muster aufnehmen.
3. Mit falschem Passwort -> erwartet Exit 1 mit der Zugangsdaten-Meldung.
4. Mit einem Group-Repo in `NEXUS_PYPI_HOSTED` -> erwartet Exit 3 aus dem
   Repo-Typ-Check, noch vor dem Upload.

---

## Nachtrag 2026-09-03: Ergebnis der Ausfuehrung

Beide Tasks umgesetzt, je Task Review und Fix-Runden; Abschluss-Review ueber den
gesamten Bereich (0 Critical, 3 Important, 14 Minor, "With fixes"), eine
Fix-Welle und ein scoped Re-Review, beide sauber. Testtreiber am Ende:
PASS 220 FAIL 0 SKIP 3 (vorher 169).

Ueber den Plan hinaus entschieden und umgesetzt:

* **curl-Fehler enden mit Exit 1**, nicht mit curls rohem Exit-Code. Die Spec
  hatte sich hier selbst widersprochen: sie schrieb das Durchreichen vor und
  reservierte gleichzeitig 2 und 3 fuer "Version existiert" und "falscher
  Repo-Typ". Reproduziert: ein Leerzeichen in `NEXUS_URL` liefert curl-Exit 3
  und waere von einem Aufrufer als falscher Repo-Typ gelesen worden. Curls Code
  steht jetzt in der Meldung.
* **Ein Zeilenumbruch in `NEXUS_USER`/`NEXUS_PASS` wird vorab abgelehnt.** Das
  curl-Config-Format kann ihn nicht darstellen; curl zitiert sonst die zweite
  Zeile woertlich auf stderr, und Jenkins maskiert nur das vollstaendige Secret,
  nicht das Fragment. Ende-zu-Ende belegt.
* **`--form "pypi.asset=@\"${ARCHIVE}\""`** mit Quotes: curl deutet `;` und `,`
  im `-F`-Wert als Trennzeichen. Ueber `buildSdist` nicht erreichbar, ueber
  `pyMonorepo.publish(archive: ...)` und den direkten Aufruf schon.
* **`check_repo_type` ist erstmals getestet** (group / proxy / hosted mit
  falschem Format / hosted-pypi), inklusive der Zusage, dass auch dieser
  curl-Aufruf die Zugangsdaten nicht in argv legt.
* Der `trap` steht direkt nach dem ersten `mktemp`.

### Bewusst zurueckgestellt — nach dem Merge

* `RC=$?` nach `cfg_credentials | curl ...` ist unter `pipefail` der Status der
  Pipeline, nicht der von curl. Praktisch schwer ausloesbar.
* Der curl-Stub liest stdin per `cat` ohne Timeout — ein kuenftiger curl-Aufruf
  ohne stdin-Pipe liesse die Suite haengen statt rot zu werden.
* `assert_contains "POST wird verwendet"` prueft einen Substring im gesamten
  argv-Dump.
* `printf '%s\n' "$BODY" >&2` gibt bei leerem Body eine Leerzeile aus.
* Der README-Satz, Nexus vergebe den Ablagepfad `/repository/<repo>/packages/...`
  aus der PKG-INFO, ist eine Behauptung ueber fremdes Serververhalten und ohne
  Einschraenkung formuliert.
* Der Abschnitt "Doppelte Versionen" zaehlt die Exit-1-Faelle nicht vollstaendig
  auf.

### Erster echter Lauf gegen ein Nexus — Pruefreihenfolge

1. Upload einer neuen Version -> erwartet HTTP 204 (201 wird mit akzeptiert) und
   `OK: <datei>`. Liefert Nexus einen anderen Erfolgsstatus, landet das im
   `*`-Zweig und wird mit Status und Body ausgegeben — sichtbar, nicht still.
2. Denselben Upload wiederholen -> erwartet Exit 2. Trifft der 400-Body weder
   `already exists` noch `does not allow updating`, landet der Fall im
   generischen 400-Zweig; dann den tatsaechlichen Wortlaut ins Muster aufnehmen.
3. Falsches Passwort -> Exit 1 mit der Zugangsdaten-Meldung (401 oder 403).
4. Ein Group-Repo in `NEXUS_PYPI_HOSTED` -> Exit 3 aus dem Repo-Typ-Check, noch
   vor dem Upload.
5. Pruefen, dass die Nexus-Version die Components-API fuer PyPI-Repos anbietet:
   ein 404 auf `/service/rest/v1/components` waere das Symptom. Fallback waere
   der Legacy-Weg (`:action=file_upload` gegen `/repository/<repo>/`), der aber
   Name, Version, filetype, pyversion und metadata_version als eigene
   Formularfelder braucht.
