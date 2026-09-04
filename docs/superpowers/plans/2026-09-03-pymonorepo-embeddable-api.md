# pyMonorepo einbettbares API — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `vars/pyMonorepo.groovy` so umbauen, dass eine bestehende Jenkins-Pipeline die Library ueber Einzel-Steps oder den Composite-Step `pyMonorepo.build(Map)` in einer eigenen Stage nutzen kann; die heutige Vollpipeline `pyMonorepo { }` bleibt als duenner Wrapper auf demselben Codepfad.

**Architecture:** Alle Funktionen bleiben in einem Var. Sieben oeffentliche Steps (`install`, `changedPackages` x2, `buildSdist`, `meta`, `publish`, `cleanup`) kapseln je genau einen Skriptaufruf mit `withEnv` und einfach gequotetem `sh`-String. `build(Map)` orchestriert sie (install -> changedPackages -> parallel je Paket -> finally archive/cleanup). `call(Closure)` ist eine Declarative Pipeline mit einer Stage, die `build(archive:false, cleanup:false)` ruft und Archivieren/Aufraeumen im eigenen `post` behaelt.

**Tech Stack:** Jenkins Shared Library (vars/), Declarative + Scripted Pipeline, Bash-Testtreiber `test/run-tests.sh` (bash 3.2, macOS). Groovy ist lokal nicht ausfuehrbar — Verifikation ist strukturell.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-03-pymonorepo-embeddable-api-design.md`. Schluesselnamen, Defaults und Signaturen exakt von dort.
- Kein Default-Parameter an irgendeiner Methode in `vars/pyMonorepo.groovy`. Wo ein Default gewuenscht ist: zwei explizite Ueberladungen.
- Jeder `sh`-Script-String ist **einfach** gequotet; vom Repo kontrollierte Werte (PKG, ARCHIVE, BASE, PACKAGES, FIELD) und Nexus-Werte gehen per `withEnv` rein. Nie `${...}` in einem `sh`-String.
- Keine Pipeline-Steps (`sh`, `echo`, `error`, `writeFile`, ...) innerhalb von GDK-Closures (`.each`, `.collect`, `.findAll`); dort nur reine Groovy-Logik. `parallel pkgs.collectEntries { ... }` ist die einzige Ausnahme und bleibt wie heute (die Branch-Closures werden von `parallel` ausgefuehrt, nicht von `collectEntries`).
- Resource-Pfad `de/firma/ci`, Zielverzeichnis `.ci-lib`, `libraryResource(resource:..., encoding:'UTF-8')`.
- Testtreiber am Ende jeder Task: `bash test/run-tests.sh` mit FAIL 0, Exit 0. Jeder neue Test braucht einen gezeigten Rotlauf (Mutation anwenden, rot, zuruecknehmen).
- Kommentare/Meldungen Deutsch; Commit-Betreff ohne Umlaute; Commit-Message endet mit `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- macOS: `sed -i ''`; kein `mapfile`, keine assoziativen Arrays im Testcode.
- Shell-Skripte unter `resources/` werden **nicht** angefasst.

---

## File Structure

| Datei | Verantwortung |
|---|---|
| `vars/pyMonorepo.groovy` | Steps, `build(Map)`, `call(Closure)`-Wrapper, private Helfer (`libDir`, `requireInstalled`, `paramOr`, `defaultBase`) |
| `test/run-tests.sh` | Strukturtests-Block `=== vars/pyMonorepo.groovy ===` (angepasst + erweitert), neuer Block `=== examples ===` |
| `examples/Jenkinsfile` | Vollpipeline-Vorlage — unveraendert |
| `examples/Jenkinsfile.embedded` | bestehende Pipeline + eine Stage mit `pyMonorepo.build(...)` |
| `examples/Jenkinsfile.steps` | bestehende Pipeline mit Einzel-Steps |
| `README-ci.md` | Abschnitt "Integration in eine bestehende Pipeline", Argument-/Step-Tabellen, Aufbau-Liste |
| `docs/superpowers/specs/2026-09-03-pymonorepo-embeddable-api-design.md` | eine Praezisierung zu `meta()` (Task 1) |

---

## Task 1: Einzel-Steps und Wrapper auf Steps umstellen

`vars/pyMonorepo.groovy` bekommt die sieben Steps; `call()` behaelt seine zwei Stages, ruft aber die Steps statt eigener `sh`-Zeilen. Danach gibt es je Skript genau eine Aufrufstelle.

**Files:**
- Modify: `vars/pyMonorepo.groovy` (vollstaendig neu geschrieben, Inhalt unten)
- Modify: `test/run-tests.sh` (Block `=== vars/pyMonorepo.groovy ===`)
- Modify: `docs/superpowers/specs/2026-09-03-pymonorepo-embeddable-api-design.md` (ein Satz)

**Interfaces:**
- Consumes: die vier Skripte mit ihren bisherigen Vertraegen (`changed-packages.sh "$BASE"` mit `PACKAGES`; `build-sdist.sh "$PKG"` -> Pfad auf stdout; `sdist-meta.sh "$ARCHIVE" <name|version>`; `publish-pypi.sh "$ARCHIVE"` mit `NEXUS_URL`, `NEXUS_PYPI_HOSTED`, `NEXUS_USER`, `NEXUS_PASS`).
- Produces (fuer Task 2 und 3): `String install()`, `List changedPackages(String base)`, `List changedPackages(String base, String packages)`, `String buildSdist(String pkg)`, `String meta(String archive, String field)`, `void publish(Map args)` mit `archive`, `nexusUrl` (Pflicht), `hostedRepo`, `credentialsId`; `void cleanup()`. Alle setzen/lesen `env.CI_LIB_DIR`.

- [ ] **Step 1: Spec-Satz zu `meta()` praezisieren**

Die Spec sagt, `field` werde als Literal in den sh-String gesetzt. Die Umsetzung ist strenger: `field` geht wie alles andere per `withEnv` (`FIELD`) rein **und** wird gegen die Whitelist geprueft. Ersetze in der Spec den Absatz

```
`meta()` validiert `field` gegen `['name', 'version']` und bricht sonst mit
`error` ab — der Wert wird nicht per withEnv, sondern als Literal in den
sh-String gesetzt, deshalb darf er nur aus dieser Whitelist kommen.
```

durch

```
`meta()` validiert `field` gegen `['name', 'version']` und bricht sonst mit
`error` ab. Der Wert geht trotzdem per `withEnv` (`FIELD`) in den Aufruf —
die Whitelist ist eine zweite Sicherung, keine Alternative zur Disziplin.
```

- [ ] **Step 2: Mutations-Tests zuerst — die neuen Strukturtests einfuegen**

Ersetze in `test/run-tests.sh` den gesamten Block von `echo "=== vars/pyMonorepo.groovy ==="` bis (ausschliesslich) `echo "=== Bilanz ==="` — er enthaelt derzeit die alte Klammer-/Tiefenpruefung mit `stage('Setup')`/`stage('Pack & Publish')` — durch:

```bash
echo
echo "=== vars/pyMonorepo.groovy ==="
GROOVY="${ROOT}/vars/pyMonorepo.groovy"
if [[ -f "$GROOVY" ]]; then
  ok "vars/pyMonorepo.groovy vorhanden"

  # Kommentare raus, sonst zaehlen Beispiele im Kopfkommentar mit.
  CODE="$(sed -E 's#//.*$##' "$GROOVY")"

  # 1) Skriptliste in install() == vorhandene Skripte
  NAMES_LINE="$(grep -oE "List names = \[[^]]*\]" <<<"$CODE")"
  NAMED="$(grep -oE "'[A-Za-z][A-Za-z0-9_.-]*\.sh'" <<<"$NAMES_LINE" | tr -d "'" | sort -u)"
  HAVE="$(cd "$SCRIPTS" && ls *.sh | sort -u)"
  assert_eq "install()-Liste == vorhandene Skripte" "$HAVE" "$NAMED"

  # 2) libraryResource: Pfad und Encoding
  LR="$(grep -oE 'libraryResource\([^)]*\)' <<<"$CODE")"
  assert_contains "libraryResource-Pfad ist de/firma/ci" "$LR" 'de/firma/ci/'
  assert_contains "libraryResource liest mit encoding UTF-8" "$LR" "encoding: 'UTF-8'"

  # 3) Zielverzeichnis mit fuehrendem Punkt, an genau einer Stelle definiert
  LIBDIR="$(grep -oE "String libDir\(\) \{ return '[^']*' \}" <<<"$CODE" | sed -E "s/.*return '([^']*)'.*/\1/")"
  if [[ "$LIBDIR" == .* ]]; then ok "libDir() beginnt mit einem Punkt ($LIBDIR)"
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

  # 6) Kein Default-Parameter (CPS: synthetische Ueberladung)
  DEFAULTS="$(grep -nE '^[A-Za-z].*\([^)]*=[^)]*\)\s*\{' <<<"$CODE" || true)"
  if [[ -z "$DEFAULTS" ]]; then ok "keine Methode mit Default-Parameter"
  else nok "keine Methode mit Default-Parameter" "$DEFAULTS"; fi

  # 7) Injection-Disziplin: jeder sh-Script-String ist einfach gequotet.
  #    Ein doppelt gequoteter sh-String (sh "..." oder script: "...") waere
  #    ein Rueckfall in Groovy-Interpolation.
  BAD_SH="$(grep -nE "(^|[^A-Za-z_])sh[[:space:]]*(\(|[[:space:]])[^']*\"" <<<"$CODE" \
            | grep -vE "script:[[:space:]]*'" || true)"
  if [[ -z "$BAD_SH" ]]; then ok "alle sh-Script-Strings einfach gequotet"
  else nok "alle sh-Script-Strings einfach gequotet" "$BAD_SH"; fi
  # ... und kein '${' in einem einfach gequoteten sh-String
  INTERP="$(grep -oE "'bash[^']*'" <<<"$CODE" | grep -F '${' || true)"
  if [[ -z "$INTERP" ]]; then ok "kein \${ in bash-Aufrufstrings"
  else nok "kein \${ in bash-Aufrufstrings" "$INTERP"; fi

  # 8) meta(): Whitelist vorhanden
  assert_contains "meta() prueft field gegen ['name', 'version']" "$CODE" "['name', 'version']"

  # 9) Klammern ausgeglichen (Kommentare ausgenommen)
  OPEN="$(tr -cd '{' <<<"$CODE" | wc -c | tr -d ' ')"; CLOSE="$(tr -cd '}' <<<"$CODE" | wc -c | tr -d ' ')"
  assert_eq "geschweifte Klammern ausgeglichen (Kommentare ausgenommen)" "$OPEN" "$CLOSE"

  if command -v groovyc >/dev/null 2>&1; then
    if groovyc -d "$TMP/groovyc" "$GROOVY" 2>"$TMP/groovyc.err"; then ok "groovyc kompiliert"
    else nok "groovyc kompiliert" "$(head -3 "$TMP/groovyc.err")"; fi
  else
    skip "groovyc Syntaxpruefung" "groovyc nicht installiert"
  fi
else
  nok "vars/pyMonorepo.groovy vorhanden" "Datei fehlt"
fi
```

- [ ] **Step 3: Tests laufen lassen — gegen die alte Groovy-Datei muessen sie rot sein**

```bash
bash test/run-tests.sh 2>&1 | sed -n '/vars\/pyMonorepo/,/Bilanz/p'; echo "Exit: ${PIPESTATUS[0]}"
```

Erwartet: rot bei "install()-Liste" (die Liste steht noch in `materializeScripts`), "libDir() beginnt mit einem Punkt" (Funktion fehlt), "genau eine sh-Aufrufstelle" (`sdist-meta.sh: 2`), und bei allen Methoden ausser `call`. Gruen bleiben nur libraryResource-Pfad/-Encoding und die Klammerbilanz; die Whitelist-Pruefung ist rot, weil `['name', 'version']` in der alten Datei nicht vorkommt. Exit 1. Wenn weniger rot ist als hier genannt, pruefe den jeweiligen Test — er wuerde sonst nichts beweisen.

- [ ] **Step 4: `vars/pyMonorepo.groovy` neu schreiben**

```groovy
// Jenkins Shared Library fuer ein Python-Monorepo: geaenderte Pakete ermitteln,
// je eine sdist bauen und in ein Nexus-PyPI-hosted-Repo hochladen.
//
// Drei Arten, es zu benutzen:
//
//   1) Vollpipeline (neues Monorepo, Jenkinsfile enthaelt nur Konfiguration):
//        @Library('ci-shared@v1.0.0') _
//        pyMonorepo { nexusUrl = 'https://nexus.example.com'; hostedRepo = 'pypi-hosted' }
//
//   2) Composite-Step in einer Stage einer BESTEHENDEN Pipeline (Task 2):
//        script { pyMonorepo.build(nexusUrl: '...', hostedRepo: 'pypi-hosted') }
//
//   3) Einzel-Steps, wenn eine Pipeline abweichen muss:
//        pyMonorepo.install()
//        def pkgs = pyMonorepo.changedPackages(base)
//        def a = pyMonorepo.buildSdist(pkg); def v = pyMonorepo.meta(a, 'version')
//        pyMonorepo.publish(archive: a, nexusUrl: '...')
//        pyMonorepo.cleanup()
//
// Die eigentliche Arbeit steckt in den Shell-Skripten unter resources/de/firma/ci/.
// Sie werden zur Laufzeit per install() auf den Agent geschrieben - ein Monorepo
// braucht keinen ci/-Ordner. Was in .sh steckt, ist lokal testbar; was in
// Groovy steckt, erst auf einem Jenkins. Deshalb bleibt Groovy duenn.
//
// Disziplin, die in JEDEM Step gilt: vom Repo kontrollierte Werte (Paketname,
// Archivpfad, Basis-Commit, Paketliste) gehen per withEnv in die Umgebung, der
// sh-String ist einfach gequotet und referenziert die Shell-Variable. Nie
// Groovy-Interpolation in einen sh-String - ein Ordnername wie
// "x'; echo INJECTED >&2; '" wuerde sonst Kommandos einschleusen.
//
// Keine Default-Parameter: Groovy erzeugt daraus eine synthetische Ueberladung,
// deren CPS-Transformation eine bekannte Fehlerquelle ist. Wo ein Default
// gewuenscht ist, gibt es zwei explizite Ueberladungen.

// ---------------------------------------------------------------------------
// Vollpipeline-Wrapper
// ---------------------------------------------------------------------------

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
                        install()

                        // Basis fuer den Diff: letzter erfolgreicher Build (Git-Plugin
                        // setzt das), sonst HEAD~1, sonst leer -> alles bauen.
                        String base = params.BUILD_ALL ? '' : defaultBase()
                        List pkgs = changedPackages(base, cfg.packages)
                        env.CHANGED = pkgs.join('\n')

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
                        List pkgs = env.CHANGED.trim().split('\n') as List
                        Map versions = [:]   // CPS-Branches laufen kooperativ, kein Sync noetig

                        parallel pkgs.collectEntries { pkg ->
                            [ (pkg): {
                                stage(pkg) {
                                    String archive  = buildSdist(pkg)
                                    String distName = meta(archive, 'name')
                                    String version  = meta(archive, 'version')
                                    echo "${pkg}: ${distName} ${version}"

                                    if (params.SKIP_UPLOAD) {
                                        echo "SKIP_UPLOAD gesetzt – ${archive} nicht hochgeladen"
                                    } else {
                                        publish(archive: archive,
                                                nexusUrl: cfg.nexusUrl,
                                                hostedRepo: cfg.hostedRepo,
                                                credentialsId: cfg.credentialsId)
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
                script { cleanup() }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Einzel-Steps
// ---------------------------------------------------------------------------

// Schreibt die Skripte aus resources/ nach libDir() und merkt sich den Pfad in
// env.CI_LIB_DIR - env, nicht lokale Variable, damit spaetere Stages und der
// post-Block ihn sehen. libraryResource liefert nur den Dateiinhalt als String;
// resources/ selbst liegt nie auf dem Agent.
//
// Aufgerufen wird immer als 'bash <pfad>': writeFile setzt kein Ausfuehrbar-Bit,
// und der Umweg ueber bash macht das auch unnoetig. Idempotent.
String install() {
    String dir = libDir()
    List names = ['changed-packages.sh', 'build-sdist.sh', 'sdist-meta.sh', 'publish-pypi.sh']
    for (String n : names) {
        writeFile file: "${dir}/${n}",
                  text: libraryResource(resource: "de/firma/ci/${n}", encoding: 'UTF-8'),
                  encoding: 'UTF-8'
    }
    env.CI_LIB_DIR = dir
    echo "Skripte nach ${dir}/ geschrieben: ${names.join(', ')}"
    return dir
}

// Geaenderte Pakete seit base; leere Basis heisst "alle". Auto-Erkennung der
// Paketordner (siehe changed-packages.sh).
List changedPackages(String base) {
    return changedPackages(base, '')
}

// Wie oben, aber mit fester Paketliste (Leerzeichen-getrennt) statt
// Auto-Erkennung. Leeres packages = Auto-Erkennung.
List changedPackages(String base, String packages) {
    requireInstalled()
    String out
    withEnv(["BASE=${base ?: ''}", "PACKAGES=${packages ?: ''}"]) {
        out = sh(returnStdout: true,
                 script: 'bash "$CI_LIB_DIR/changed-packages.sh" "$BASE"').trim()
    }
    return out ? (out.split('\n') as List) : []
}

// Baut die sdist eines Paketordners und gibt den Pfad zurueck, den das Skript
// meldet (dist/<datei>). Der Dateiname wird NICHT selbst zusammengebaut, weil
// setuptools Name und Version normalisiert.
String buildSdist(String pkg) {
    requireInstalled()
    String archive
    withEnv(["PKG=${pkg}"]) {
        archive = sh(returnStdout: true,
                     script: 'bash "$CI_LIB_DIR/build-sdist.sh" "$PKG"').trim()
    }
    return archive
}

// Name oder Version aus der PKG-INFO der sdist - nicht aus dem Dateinamen,
// weil Paketnamen selbst Bindestriche enthalten duerfen. field ist auf die
// Whitelist begrenzt und geht trotzdem per withEnv rein: die Whitelist ist eine
// zweite Sicherung, keine Alternative zur Disziplin.
String meta(String archive, String field) {
    requireInstalled()
    if (!(field in ['name', 'version'])) {
        error "pyMonorepo.meta: field muss 'name' oder 'version' sein, war '${field}'"
    }
    String value
    withEnv(["ARCHIVE=${archive}", "FIELD=${field}"]) {
        value = sh(returnStdout: true,
                   script: 'bash "$CI_LIB_DIR/sdist-meta.sh" "$ARCHIVE" "$FIELD"').trim()
    }
    return value
}

// Laedt eine sdist in das Nexus-PyPI-HOSTED-Repo.
//   publish(archive: 'dist/x-1.0.tar.gz', nexusUrl: 'https://nexus...',
//           hostedRepo: 'pypi-hosted', credentialsId: 'nexus-pypi-deploy')
// Das Secret wird nur fuer diesen einen sh-Schritt gebunden und von Jenkins im
// Log maskiert; das Skript liest es aus der Umgebung, nicht aus argv.
void publish(Map args) {
    requireInstalled()
    for (String k : ['archive', 'nexusUrl']) {
        if (!args[k]) {
            error "pyMonorepo.publish: ${k} fehlt"
        }
    }
    withEnv(["NEXUS_URL=${args.nexusUrl}",
             "NEXUS_PYPI_HOSTED=${args.hostedRepo ?: 'pypi-hosted'}",
             "ARCHIVE=${args.archive}"]) {
        withCredentials([usernamePassword(
                credentialsId: args.credentialsId ?: 'nexus-pypi-deploy',
                usernameVariable: 'NEXUS_USER',
                passwordVariable: 'NEXUS_PASS')]) {
            sh 'bash "$CI_LIB_DIR/publish-pypi.sh" "$ARCHIVE"'
        }
    }
}

// Entfernt dist/ und das Skriptverzeichnis. Idempotent; laeuft auch, wenn
// install() nie aufgerufen wurde.
void cleanup() {
    sh 'rm -rf dist'
    if (env.CI_LIB_DIR) {
        sh 'rm -rf "$CI_LIB_DIR"'
    }
}

// ---------------------------------------------------------------------------
// Private Helfer
// ---------------------------------------------------------------------------

// Das Ziel liegt im Checkout, faellt dort aber nicht auf: der fuehrende Punkt
// haelt es aus dem '*/'-Glob von changed-packages.sh heraus. Als Paket wuerde
// es ohnehin nie zaehlen - dafuer fehlen pyproject.toml/setup.py/setup.cfg.
// Eine Methode statt eines statischen Felds: statische Felder in vars/ werden
// zwischen Builds geteilt und machen mit CPS/Serialisierung Aerger.
private String libDir() { return '.ci-lib' }

private void requireInstalled() {
    if (!env.CI_LIB_DIR) {
        error 'pyMonorepo: install() wurde nicht aufgerufen - env.CI_LIB_DIR fehlt'
    }
}

// Basis fuer den Diff: letzter erfolgreicher Build (Git-Plugin setzt das),
// sonst HEAD~1, sonst leer -> alles bauen.
private String defaultBase() {
    return env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?:
        sh(returnStdout: true, script: 'git rev-parse HEAD~1 2>/dev/null || true').trim()
}
```

- [ ] **Step 5: Tests gruen, Gegenproben fuer die neuen Tests**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh 2>&1 | tail -3
```

Erwartet: FAIL 0, Exit 0. Dann vier Mutationen einzeln, je Test rot, Datei danach per `cp` aus einer Sicherung wiederherstellen, `git status --short` leer:

```bash
G=vars/pyMonorepo.groovy; BAK="$(mktemp)"; cp $G "$BAK"
# (a) Default-Parameter einschmuggeln -> Test 6 rot
sed -i '' "s/^String meta(String archive, String field) {/String meta(String archive, String field = 'version') {/" $G
bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'; cp "$BAK" $G
# (b) doppelt gequoteten sh-String einbauen -> Test 7 rot
sed -i '' "s|sh 'rm -rf dist'|sh \"rm -rf dist\"|" $G
bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'; cp "$BAK" $G
# (c) Interpolation in bash-String -> Test 7b rot
sed -i '' "s|'bash \"\$CI_LIB_DIR/build-sdist.sh\" \"\$PKG\"'|'bash \"\$CI_LIB_DIR/build-sdist.sh\" \${pkg}'|" $G
bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'; cp "$BAK" $G
# (d) zweite Aufrufstelle fuer sdist-meta.sh -> Test 4 rot
sed -i '' "s|^void cleanup() {|void cleanup() {\n    sh 'bash \"\$CI_LIB_DIR/sdist-meta.sh\" x name'|" $G
bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'; cp "$BAK" $G
rm "$BAK"; git status --short
```

- [ ] **Step 6: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add vars/pyMonorepo.groovy test/run-tests.sh docs/superpowers/specs/2026-09-03-pymonorepo-embeddable-api-design.md
git commit -m "$(cat <<'EOF'
pyMonorepo: Einzel-Steps, Wrapper ruft sie statt eigener sh-Zeilen

install(), changedPackages(), buildSdist(), meta(), publish() und cleanup()
kapseln je genau einen Skriptaufruf mit withEnv und einfach gequotetem
sh-String. Die Vollpipeline behaelt ihre zwei Stages, ruft aber die Steps -
je Skript gibt es jetzt eine Aufrufstelle. Strukturtests pruefen Methoden,
Default-Parameter, sh-Quoting und Aufrufzahlen.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Composite `build(Map)` und Wrapper auf eine Stage

**Files:**
- Modify: `vars/pyMonorepo.groovy` (neue Methode `build`, Helfer `paramOr`; `call()` auf eine Stage)
- Modify: `test/run-tests.sh` (Block `=== vars/pyMonorepo.groovy ===` erweitern)

**Interfaces:**
- Consumes: alle Steps aus Task 1.
- Produces: `Map build(Map args)` mit Schluesseln `nexusUrl` (Pflicht), `hostedRepo`, `credentialsId`, `packages`, `buildAll`, `skipUpload`, `base`, `archive`, `cleanup`; Rueckgabe `Map<String,String>` Paket -> `"<distName> <version>"`. Unbekannte Schluessel -> `error`.

- [ ] **Step 1: Tests zuerst — ergaenze im Groovy-Block vor dem `groovyc`-Teil**

```bash
  # 10) build(Map) vorhanden, ohne pipeline{}-Block, mit Schluessel-Whitelist
  if grep -qF 'Map build(Map args)' <<<"$CODE"; then ok "Methode vorhanden: Map build(Map args)"
  else nok "Methode vorhanden: Map build(Map args)" "nicht gefunden"; fi
  BUILD_BODY="$(awk '/^Map build\(Map args\)/{f=1} f{print} f&&/^}/{exit}' <<<"$CODE")"
  if [[ -n "$BUILD_BODY" ]] && ! grep -qE 'pipeline[[:space:]]*\{' <<<"$BUILD_BODY"; then
    ok "build() enthaelt keinen pipeline{}-Block"
  else nok "build() enthaelt keinen pipeline{}-Block" "Rumpf leer oder pipeline{} gefunden"; fi
  assert_contains "build() kennt die erlaubten Schluessel" "$BUILD_BODY" \
    "['nexusUrl', 'hostedRepo', 'credentialsId', 'packages', 'buildAll', 'skipUpload', 'base', 'archive', 'cleanup']"
  assert_contains "build() lehnt unbekannte Schluessel ab" "$BUILD_BODY" 'unbekannte Argumente'
  assert_contains "build() archiviert und raeumt im finally auf" "$BUILD_BODY" 'finally'
  # 11) Wrapper ruft build() mit archive:false, cleanup:false (post uebernimmt)
  CALL_BODY="$(awk '/^def call\(Closure body\)/{f=1} f{print} f&&/^}/{exit}' <<<"$CODE")"
  assert_contains "call() ruft build(...)" "$CALL_BODY" 'build('
  assert_contains "call() ruft build mit archive: false" "$CALL_BODY" 'archive: false'
  assert_contains "call() ruft build mit cleanup: false" "$CALL_BODY" 'cleanup: false'
  if ! grep -qF "stage('Pack & Publish')" <<<"$CALL_BODY"; then ok "call() hat keine eigene Pack-&-Publish-Stage mehr"
  else nok "call() hat keine eigene Pack-&-Publish-Stage mehr" "stage('Pack & Publish') noch vorhanden"; fi
  # 12) params-Zugriff abgesichert
  assert_contains "paramOr() sichert params per binding.hasVariable ab" "$CODE" "binding.hasVariable('params')"
```

- [ ] **Step 2: Tests laufen lassen — rot**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'
```

Erwartet: alle neuen Assertions rot (build fehlt, call() hat noch Pack & Publish, kein paramOr). Exit 1.

- [ ] **Step 3: `build()` und `paramOr()` einfuegen, `call()` umstellen**

Fuege unter der Ueberschrift `// Einzel-Steps` (vor `String install()`) einen neuen Abschnitt ein:

```groovy
// ---------------------------------------------------------------------------
// Composite-Step fuer bestehende Pipelines
// ---------------------------------------------------------------------------

// Der ganze Ablauf in EINER Stage des Aufrufers:
//
//   stage('Pakete') { steps { script {
//       pyMonorepo.build(nexusUrl: 'https://nexus...', hostedRepo: 'pypi-hosted')
//   } } }
//
// Argumente (alle ausser nexusUrl optional):
//   hostedRepo, credentialsId, packages  - wie in der Vollpipeline
//   buildAll, skipUpload  - Argument gewinnt; fehlt es, params.BUILD_ALL /
//                           params.SKIP_UPLOAD, falls die Pipeline sie hat; sonst false
//   base                  - Diff-Basis; fehlt sie, wie ueblich berechnet
//   archive (true)        - dist/*.tar.gz am Ende archivieren
//   cleanup (true)        - dist/ und .ci-lib/ am Ende entfernen
// archive/cleanup auf false setzen, wenn der eigene post-Block das uebernimmt
// (dann dort pyMonorepo.cleanup() aufrufen). Rueckgabe: Paket -> "name version".
Map build(Map args) {
    List allowed = ['nexusUrl', 'hostedRepo', 'credentialsId', 'packages', 'buildAll', 'skipUpload', 'base', 'archive', 'cleanup']
    List unknown = []
    for (String k : args.keySet()) {
        if (!(k in allowed)) { unknown << k }
    }
    if (unknown) {
        error "pyMonorepo.build: unbekannte Argumente ${unknown} - erlaubt: ${allowed}"
    }
    if (!args.nexusUrl) {
        error 'pyMonorepo.build: nexusUrl fehlt - Basis-URL der Nexus-Instanz setzen'
    }
    boolean doArchive  = args.containsKey('archive')    ? (args.archive    as boolean) : true
    boolean doCleanup  = args.containsKey('cleanup')    ? (args.cleanup    as boolean) : true
    boolean buildAll   = args.containsKey('buildAll')   ? (args.buildAll   as boolean) : paramOr('BUILD_ALL', false)
    boolean skipUpload = args.containsKey('skipUpload') ? (args.skipUpload as boolean) : paramOr('SKIP_UPLOAD', false)
    String hostedRepo    = args.hostedRepo    ?: 'pypi-hosted'
    String credentialsId = args.credentialsId ?: 'nexus-pypi-deploy'
    Map versions = [:]   // CPS-Branches laufen kooperativ, kein Sync noetig

    try {
        install()
        String base = args.containsKey('base') ? (args.base ?: '') : (buildAll ? '' : defaultBase())
        List pkgs = changedPackages(base, args.packages ?: '')

        echo "Basis   : ${base ?: '(keine – alles)'}"
        echo "Pakete  : ${pkgs.join(', ') ?: '(keine Änderungen)'}"

        if (pkgs.isEmpty()) {
            currentBuild.description = 'keine Paketänderungen'
            return versions
        }
        currentBuild.description = "${pkgs.size()} Paket(e): ${pkgs.join(', ')}"

        parallel pkgs.collectEntries { pkg ->
            [ (pkg): {
                stage(pkg) {
                    String archive  = buildSdist(pkg)
                    String distName = meta(archive, 'name')
                    String version  = meta(archive, 'version')
                    echo "${pkg}: ${distName} ${version}"

                    if (skipUpload) {
                        echo "skipUpload – ${archive} nicht hochgeladen"
                    } else {
                        publish(archive: archive, nexusUrl: args.nexusUrl,
                                hostedRepo: hostedRepo, credentialsId: credentialsId)
                    }
                    versions[pkg] = "${distName} ${version}"
                }
            }]
        }

        currentBuild.description = versions.sort().collect { k, v -> v }.join(', ')
        return versions
    } finally {
        // Erst archivieren, dann aufraeumen - sonst ist dist/ schon weg.
        if (doArchive) {
            archiveArtifacts artifacts: 'dist/*.tar.gz', allowEmptyArchive: true, fingerprint: true
        }
        if (doCleanup) {
            cleanup()
        }
    }
}
```

Fuege bei den privaten Helfern ein:

```groovy
// params existiert nur, wenn die Pipeline Parameter definiert (und in manchen
// Kontexten gar nicht). Ohne die Absicherung wuerde ein eingebetteter Aufruf in
// einer Pipeline ohne parameters{} mit MissingPropertyException sterben.
private boolean paramOr(String name, boolean dflt) {
    if (!binding.hasVariable('params')) { return dflt }
    def p = params
    return p.containsKey(name) ? (p[name] as boolean) : dflt
}
```

Ersetze in `call()` den kompletten `stages { ... }`-Block (beide Stages) durch:

```groovy
        stages {
            stage('Build') {
                steps {
                    script {
                        // Archivieren und Aufraeumen macht der post-Block unten -
                        // der laeuft auch, wenn build() abbricht.
                        build(nexusUrl: cfg.nexusUrl, hostedRepo: cfg.hostedRepo,
                              credentialsId: cfg.credentialsId, packages: cfg.packages,
                              archive: false, cleanup: false)
                    }
                }
            }
        }
```

`post` bleibt unveraendert. Aktualisiere den Kopfkommentar der Datei: der Hinweis "(Task 2)" bei Variante 2 entfaellt.

- [ ] **Step 4: Tests gruen, Gegenproben**

```bash
cd /Users/bengoo/projects/jenkins && bash test/run-tests.sh 2>&1 | tail -3
G=vars/pyMonorepo.groovy; BAK="$(mktemp)"; cp $G "$BAK"
# (a) pipeline{} in build() -> Test 10 rot
sed -i '' "s|^Map build(Map args) {|Map build(Map args) {\n    pipeline { }|" $G
bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'; cp "$BAK" $G
# (b) archive: false aus call() entfernen -> Test 11 rot
sed -i '' "s|archive: false, cleanup: false|cleanup: false|" $G
bash test/run-tests.sh 2>&1 | grep -E 'FAIL|Bilanz'; cp "$BAK" $G
rm "$BAK"; git status --short
```

Erwartet: erster Lauf FAIL 0 / Exit 0; beide Gegenproben je mindestens ein FAIL; danach Repo sauber.

- [ ] **Step 5: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add vars/pyMonorepo.groovy test/run-tests.sh
git commit -m "$(cat <<'EOF'
pyMonorepo.build(): Composite-Step fuer bestehende Pipelines

Laeuft in einer Stage des Aufrufers: install, changedPackages, parallel je
Paket bauen/lesen/publishen, im finally archivieren und aufraeumen.
Argumente gewinnen, sonst Fallback auf params.BUILD_ALL/SKIP_UPLOAD,
abgesichert per binding.hasVariable. Unbekannte Schluessel sind ein
Fehler. Die Vollpipeline ist jetzt eine Stage, die build() mit
archive:false, cleanup:false ruft - post uebernimmt wie bisher.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Vorlagen, README, Beispiel-Tests

**Files:**
- Create: `examples/Jenkinsfile.embedded`, `examples/Jenkinsfile.steps`
- Modify: `README-ci.md`
- Modify: `test/run-tests.sh` (neuer Block `=== examples ===` vor `=== Bilanz ===`)

**Interfaces:**
- Consumes: alle oeffentlichen Methoden aus Task 1 und 2.
- Produces: nichts fuer spaetere Tasks.

- [ ] **Step 1: Test zuerst — jede in den Beispielen benutzte Methode muss existieren**

Fuege in `test/run-tests.sh` direkt vor `echo "=== Bilanz ==="` ein:

```bash
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
```

- [ ] **Step 2: Rot bestaetigen** — `bash test/run-tests.sh | grep -E 'FAIL|Bilanz'`: beide Dateien fehlen -> zwei FAIL.

- [ ] **Step 3: `examples/Jenkinsfile.embedded`**

```groovy
// Vorlage: Integration in eine BESTEHENDE Declarative Pipeline. Die Pipeline
// behaelt ihre Stages, ihre Parameter und ihren post-Block; eine Stage ruft
// pyMonorepo.build(...). Als 'Jenkinsfile' in die Wurzel des Monorepos.
@Library('ci-shared@v1.0.0') _

pipeline {
    agent any

    options { timestamps() }

    parameters {
        // Optional: wenn vorhanden, liest build() sie automatisch. Sonst
        // buildAll:/skipUpload: als Argument uebergeben.
        booleanParam(name: 'BUILD_ALL',   defaultValue: false, description: 'Alle Pakete bauen')
        booleanParam(name: 'SKIP_UPLOAD', defaultValue: false, description: 'Nur bauen, kein Upload')
    }

    stages {
        stage('Lint') {
            steps { sh 'echo "eigene Lint-Stage der bestehenden Pipeline"' }
        }
        stage('Test') {
            steps { sh 'echo "eigene Test-Stage der bestehenden Pipeline"' }
        }
        stage('Pakete') {
            steps {
                script {
                    // Ermittelt geaenderte Pakete, baut je eine sdist, laedt hoch.
                    // Archiviert dist/*.tar.gz und raeumt dist/ + .ci-lib/ selbst auf.
                    def versions = pyMonorepo.build(
                        nexusUrl  : 'https://nexus.example.com',
                        hostedRepo: 'pypi-hosted',
                        // credentialsId: 'nexus-pypi-deploy',   // Default
                        // packages     : 'alpha beta',          // Default: Auto-Erkennung
                    )
                    echo "veroeffentlicht: ${versions}"
                }
            }
        }
    }

    post {
        always { echo 'eigener post-Block der bestehenden Pipeline' }
    }
}
```

- [ ] **Step 4: `examples/Jenkinsfile.steps`**

```groovy
// Vorlage: Einzel-Steps fuer Pipelines, die vom Standardablauf abweichen -
// hier: sequentiell statt parallel, Upload nur auf main, Aufraeumen im post.
@Library('ci-shared@v1.0.0') _

pipeline {
    agent any

    stages {
        stage('Pakete bauen') {
            steps {
                script {
                    pyMonorepo.install()
                    String base = env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: ''
                    List pkgs = pyMonorepo.changedPackages(base)
                    echo "Pakete: ${pkgs}"
                    for (String pkg : pkgs) {
                        String archive = pyMonorepo.buildSdist(pkg)
                        String version = pyMonorepo.meta(archive, 'version')
                        echo "${pkg}: ${version} -> ${archive}"
                        if (env.BRANCH_NAME == 'main') {
                            pyMonorepo.publish(archive: archive,
                                               nexusUrl: 'https://nexus.example.com',
                                               hostedRepo: 'pypi-hosted')
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'dist/*.tar.gz', allowEmptyArchive: true, fingerprint: true
        }
        cleanup {
            script { pyMonorepo.cleanup() }
        }
    }
}
```

- [ ] **Step 5: README-ci.md ergaenzen**

(a) In der Aufbau-Liste nach `examples/Jenkinsfile` einfuegen:

```
    examples/Jenkinsfile.embedded          bestehende Pipeline + eine Stage mit pyMonorepo.build()
    examples/Jenkinsfile.steps             bestehende Pipeline mit Einzel-Steps
```

(b) Neuen Abschnitt nach "Konfiguration" einfuegen:

```markdown
## Integration in eine bestehende Pipeline

Die Vollpipeline `pyMonorepo { ... }` ersetzt den ganzen Jenkinsfile. Wer schon
eine Pipeline mit eigenen Stages hat, bindet die Library stattdessen in einer
Stage ein — ein Declarative `pipeline {}` laesst sich nicht in ein anderes
einbetten, ein Step schon.

### Composite-Step (Normalfall)

    @Library('ci-shared@v1.0.0') _
    pipeline {
        ...
        stage('Pakete') {
            steps { script {
                pyMonorepo.build(nexusUrl: 'https://nexus.example.com', hostedRepo: 'pypi-hosted')
            } }
        }
    }

Vollstaendiges Beispiel: `examples/Jenkinsfile.embedded`.

| Argument | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `nexusUrl` | ja | -- | Basis-URL der Nexus-Instanz |
| `hostedRepo` | nein | `pypi-hosted` | HOSTED-Repo, nie die Group |
| `credentialsId` | nein | `nexus-pypi-deploy` | Username/Password-Credential |
| `packages` | nein | `''` | feste Paketliste; leer = Auto-Erkennung |
| `buildAll` | nein | `params.BUILD_ALL`, sonst `false` | alles bauen |
| `skipUpload` | nein | `params.SKIP_UPLOAD`, sonst `false` | Dry-Run |
| `base` | nein | berechnet | Diff-Basis (`GIT_PREVIOUS_SUCCESSFUL_COMMIT`, sonst `HEAD~1`) |
| `archive` | nein | `true` | `dist/*.tar.gz` am Ende archivieren |
| `cleanup` | nein | `true` | `dist/` und `.ci-lib/` am Ende entfernen |

`buildAll`/`skipUpload`: ein uebergebenes Argument gewinnt. Fehlt es, liest
`build()` `params.BUILD_ALL`/`params.SKIP_UPLOAD`, falls die Pipeline solche
Parameter definiert; sonst `false`. Unbekannte Argumente sind ein Fehler.

`archive`/`cleanup` laufen in einem `finally`, also auch bei Abbruch. Wer das
lieber im eigenen `post` macht, setzt beide auf `false` und ruft dort
`pyMonorepo.cleanup()` (Beispiel: `examples/Jenkinsfile.steps`).

Rueckgabe: `Map` Paket -> `"<name> <version>"`; leer, wenn nichts geaendert war.

### Einzel-Steps

Fuer Pipelines, die abweichen muessen (sequentiell, Upload nur auf bestimmten
Branches, eigene Stage je Paket):

| Step | Rueckgabe | Bedeutung |
|---|---|---|
| `pyMonorepo.install()` | Pfad | Skripte nach `.ci-lib/` schreiben; **zuerst** aufrufen |
| `pyMonorepo.changedPackages(base)` | `List` | geaenderte Pakete; leere Basis = alle |
| `pyMonorepo.changedPackages(base, packages)` | `List` | mit fester Paketliste |
| `pyMonorepo.buildSdist(pkg)` | Archivpfad | sdist bauen |
| `pyMonorepo.meta(archive, 'name'\|'version')` | String | aus der PKG-INFO |
| `pyMonorepo.publish(archive:, nexusUrl:, hostedRepo:, credentialsId:)` | -- | Upload |
| `pyMonorepo.cleanup()` | -- | `dist/` und `.ci-lib/` entfernen |

Jeder Step ausser `install()` bricht mit klarer Meldung ab, wenn `install()`
fehlt. Alle Steps funktionieren in Declarative (`script {}`) und Scripted
Pipelines. Vollstaendiges Beispiel: `examples/Jenkinsfile.steps`.

Auch hier gehoert `.ci-lib/` in die `.gitignore` des Monorepos.
```

(c) Im Abschnitt "Artefakte und Aufraeumen" einen Satz ergaenzen: "Eingebettet per `build()` passiert dasselbe im `finally` des Steps (Argumente `archive`/`cleanup`)."

- [ ] **Step 6: Gegenpruefen und Tests**

```bash
cd /Users/bengoo/projects/jenkins
# Alle Methoden, die README und Beispiele nennen, existieren?
grep -ohE 'pyMonorepo\.[A-Za-z]+' README-ci.md examples/* | sort -u | sed 's/pyMonorepo\.//' \
  | while read -r M; do grep -qE "^[A-Za-z<>, ]+ ${M}\(" vars/pyMonorepo.groovy && echo "ok $M" || echo "FEHLT $M"; done
# build()-Argumente im README == allowed-Liste im Code?
DOKU_F="$(mktemp)"; CODE_F="$(mktemp)"
sed -n '/^| Argument/,/^$/p' README-ci.md | awk -F'|' 'NF>2{gsub(/[ `]/,"",$2);print $2}' | grep -vE '^(Argument|-*)$' | sort > "$DOKU_F"
grep -oE "allowed = \[[^]]*\]" vars/pyMonorepo.groovy | grep -oE "'[a-zA-Z]+'" | tr -d "'" | sort > "$CODE_F"
diff "$DOKU_F" "$CODE_F" && echo "Argumente identisch"
bash test/run-tests.sh 2>&1 | tail -2; git status --short
```

Erwartet: alle `ok`, "Argumente identisch", FAIL 0, Exit 0, Repo sauber.

- [ ] **Step 7: Commit**

```bash
cd /Users/bengoo/projects/jenkins
git add examples README-ci.md test/run-tests.sh
git commit -m "$(cat <<'EOF'
Vorlagen und README fuer die Integration in bestehende Pipelines

examples/Jenkinsfile.embedded zeigt eine bestehende Pipeline mit einer
Stage, die pyMonorepo.build() ruft; examples/Jenkinsfile.steps die
Einzel-Steps. README beschreibt beide Wege mit Argument- und Step-Tabelle.
Ein Test prueft, dass jede in Beispielen und README genannte Methode in
vars/pyMonorepo.groovy definiert ist.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Nach dem Plan

Erster Jenkins-Lauf, zusaetzlich zur Liste im vorigen Plan: (0) laedt das Var mit
`call()` **und** benannten Methoden; (7) laeuft `build()` eingebettet in einer
fremden Stage, inklusive `stage(pkg)` innerhalb von `parallel` in einem
`script {}`-Block; (8) `binding.hasVariable('params')` in einer Pipeline ohne
`parameters {}`.

---

## Nachtrag 2026-09-03: Ergebnis der Ausfuehrung

Alle drei Tasks umgesetzt, je Task Review und Fix-Runden; Abschluss-Review ueber
den gesamten Bereich (0 Critical, 7 Important, 11 Minor, "With fixes"),
eine Fix-Welle und ein scoped Re-Review, beide sauber. Testtreiber am Ende:
PASS 169 FAIL 0 SKIP 3.

Ueber den Plan hinaus entschieden und umgesetzt:

* `paramOr()` liest `params` NUR noch per Property-Zugriff. Der urspruenglich
  geplante `binding.hasVariable('params')`-Zweig war wirkungslos (`params` ist
  eine GlobalVariable ohne Binding-Eintrag) und zwang der Library eine
  trusted-Installation auf, weil `getBinding()` im Sandbox verboten ist. Die
  Library laeuft jetzt auch folder-scoped. `call()` reicht `buildAll`/
  `skipUpload` zusaetzlich explizit durch.
* `toBool()` parst Strings statt Groovy-Truthiness: `'false' as boolean` waere
  `true` gewesen, ein `string`-Parameter `'false'` haette also das Gegenteil
  bewirkt.
* `this.build()` / `this.cleanup()` in `call()` wegen Namenskollision mit den
  globalen Steps `build` und dem Declarative-`cleanup`-Block.
* Im `finally` von `build()` wird `InterruptedException` weitergeworfen (Abort
  darf nicht verschluckt werden), andere Fehler beim Aufraeumen nur geloggt.
* `cleanup()` loescht nur `dist/*.tar.gz` und entfernt `dist/` nur, wenn es
  dadurch leer wird — eingebettet gehoert der Workspace dem Aufrufer, und
  `dist/` ist ein verbreiteter Ausgabeordner.
* Der Kommentar-Stripper im Testtreiber ist quoting-bewusst (awk statt sed).
  Vorher schnitt er `//` auch in String-Literalen; eine echte
  `${base}`-Injection lief dadurch mit FAIL 0 durch, sobald im `sh`-String eine
  URL stand.

### Bewusst zurueckgestellt — nach dem Merge

* `cfg.packages` wird an einen `String`-Parameter gebunden; eine `List` in der
  Config-Closure wuerfe `MissingMethodException`.
* `build()` ueberschreibt `currentBuild.description` ohne Opt-out (dokumentiert).
* Ein Top-Level-Paketordner namens `failFast` wuerde von `parallel` als Option
  statt als Branch gelesen.
* Der examples-Test wuerde `pyMonorepo.groovy` in einem Beispiel-Kommentar als
  Methode `groovy` lesen (latenter False-Positive).

### Erster echter Jenkins-Lauf — Pruefreihenfolge

Zusaetzlich zur Liste im vorigen Plan, getrennt nach Einstiegspunkt:

1. Laedt das Var mit `call()` UND benannten Methoden?
2. Vollpipeline: baut sie auf? `cfg.keepBuilds` im `options`-Block bleibt der
   erste Fehlerkandidat.
3. Vollpipeline mit `BUILD_ALL` und `SKIP_UPLOAD`: wirken beide Haken wirklich?
   (Das war die Regression, die `paramOr()` verursacht haette.)
4. Eingebettet: `pyMonorepo.build(...)` in einer fremden Stage — laeuft
   `parallel` mit `stage(pkg)` dort, und werden `dist/` und `.ci-lib/` wie
   dokumentiert behandelt?
5. Eingebettet ohne `parameters {}` in der fremden Pipeline: greift der
   `paramOr()`-Fallback ohne Exception?
6. Einzel-Steps: `install()` -> `changedPackages()` -> `buildSdist()` ->
   `meta()` -> `publish()` -> `cleanup()`, und ein Step nach `cleanup()` muss
   mit "install() wurde nicht aufgerufen" abbrechen.
