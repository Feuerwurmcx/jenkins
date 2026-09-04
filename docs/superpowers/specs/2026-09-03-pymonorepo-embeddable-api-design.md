# pyMonorepo: einbettbares API fuer bestehende Jenkins-Pipelines

Datum: 2026-09-03. Baut auf `2026-09-03-pymonorepo-shared-library-design.md` auf.

## Problem

`vars/pyMonorepo.groovy` definiert heute die **gesamte** Pipeline: `call(Closure)`
enthaelt einen Declarative `pipeline {}`-Block. Ein `pipeline {}` laesst sich nicht
in ein anderes einbetten. Eine bestehende Pipeline mit eigenen Stages, eigenem
`parameters {}` und eigenem `post {}` kann die Library damit nicht nutzen, ohne
sich komplett durch sie ersetzen zu lassen.

Neue Anforderung: der Code muss in eine bestehende Jenkins-Pipeline integrierbar
sein.

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| Form der Integration | Einzel-Steps **plus** ein Composite-Step; die heutige Vollpipeline bleibt als duenner Wrapper darauf |
| Parameterfluss eingebettet | Explizite Argumente gewinnen; fehlen sie, Fallback auf `params.BUILD_ALL` / `params.SKIP_UPLOAD` (falls vorhanden) und Basis-Berechnung wie heute |
| Datei | Alles bleibt in `vars/pyMonorepo.groovy` (ein Var darf `call()` und benannte Methoden haben) |
| Ein Codepfad | `build()` ruft die Steps, die Vollpipeline ruft `build()`. Nichts doppelt |

Bewusst nicht gemacht (YAGNI): keine Aufteilung in mehrere Vars oder `src/`-Klassen,
kein `dir`-Argument an jedem Step (Zustand liegt in `env.CI_LIB_DIR`), keine
Unterstuetzung fuer mehrere gleichzeitig installierte Skriptverzeichnisse.

## Drei Ebenen

| Ebene | Aufruf | Zielgruppe |
|---|---|---|
| Einzel-Steps | `pyMonorepo.install()`, `.changedPackages(base)`, `.buildSdist(pkg)`, `.meta(archive, feld)`, `.publish(Map)`, `.cleanup()` | Pipelines, die vom Standardablauf abweichen |
| Composite | `pyMonorepo.build(Map)` in einer `script {}`-Stage | bestehende Pipelines, Normalfall |
| Vollpipeline | `pyMonorepo { nexusUrl = ... }` | neue Monorepos, wie bisher |

Alle Ebenen funktionieren in Declarative (innerhalb `script {}`) und in Scripted
Pipelines gleichermassen, weil sie nur normale Pipeline-Steps aufrufen.

## Einzel-Steps: Vertraege

Gemeinsame Regeln:

* Kein Default-Parameter an irgendeiner Methode (Groovy erzeugt daraus eine
  synthetische Ueberladung, deren CPS-Transformation eine bekannte Fehlerquelle
  ist). Wo ein Default gewuenscht ist, gibt es zwei explizite Ueberladungen.
* Jeder vom Repo kontrollierte Wert (Paketname, Archivpfad, Basis-Commit,
  Paketliste) geht per `withEnv` in die Umgebung; der `sh`-String ist einfach
  gequotet und referenziert die Shell-Variable. Nie Groovy-Interpolation in
  einen `sh`-String. Das ist dieselbe Disziplin wie beim Nexus-Secret.
* Jeder Step ausser `install()` und `cleanup()` prueft `env.CI_LIB_DIR` und
  bricht mit `error 'pyMonorepo: install() wurde nicht aufgerufen'` ab, wenn
  es fehlt. `cleanup()` bewusst nicht: es laeuft aus dem `post`-Block, auch
  wenn `install()` nie erreicht wurde (z. B. weil `Setup` schon vorher
  scheitert) - eine Pruefung dort wuerde jeden solchen Build zusaetzlich rot
  faerben, obwohl es nichts aufzuraeumen gibt.

| Step | Signatur | Verhalten |
|---|---|---|
| `install()` | `String install()` | Schreibt die vier Skripte per `libraryResource` nach `.ci-lib`, setzt `env.CI_LIB_DIR = '.ci-lib'`, gibt den Pfad zurueck. Idempotent. |
| `changedPackages(base)` | `List<String> changedPackages(String base)` | Ruft `changed-packages.sh "$BASE"`; leere Basis heisst "alles". `PACKAGES` leer. |
| `changedPackages(base, packages)` | `List<String> changedPackages(String base, String packages)` | Wie oben, `PACKAGES` gesetzt. |
| `buildSdist(pkg)` | `String buildSdist(String pkg)` | Ruft `build-sdist.sh "$PKG"`, gibt den Archivpfad (`dist/<datei>`) zurueck. |
| `meta(archive, field)` | `String meta(String archive, String field)` | Ruft `sdist-meta.sh "$ARCHIVE" <field>`; `field` ist `name` oder `version` (Whitelist als zweite Sicherung; geht per withEnv rein). |
| `publish(args)` | `void publish(Map args)` | Pflicht: `archive`, `nexusUrl`. Optional: `hostedRepo` (`pypi-hosted`), `credentialsId` (`nexus-pypi-deploy`). `withCredentials` nur um den einen `sh`-Schritt. |
| `cleanup()` | `void cleanup()` | Entfernt die eigenen `dist/*.tar.gz` (und `dist/` selbst nur, wenn dadurch leer - siehe I-1 im Abschluss-Review) und `rm -rf "$CI_LIB_DIR"` (nur wenn gesetzt); setzt danach `env.CI_LIB_DIR` zurueck, ein Step danach verlangt wieder `install()`. Idempotent. |

`meta()` validiert `field` gegen `['name', 'version']` und bricht sonst mit
`error` ab. Der Wert geht trotzdem per `withEnv` (`FIELD`) in den Aufruf —
die Whitelist ist eine zweite Sicherung, keine Alternative zur Disziplin.

## Composite: `build(Map args)`

Laeuft innerhalb einer Stage des Aufrufers. Ablauf:

1. `install()`
2. Basis bestimmen (siehe Parameterfluss), `changedPackages(base, packages)`
3. Log wie heute ("Basis : ...", "Pakete : ..."); `currentBuild.description`
   setzen; bei leerer Liste `return [:]`
4. `parallel` je Paket, jeder Branch in einer eigenen `stage(pkg)`:
   `buildSdist` -> `meta(name)` + `meta(version)` -> `publish` (ausser `skipUpload`)
5. `currentBuild.description` auf die Versionsliste; Rueckgabe
   `Map<String, String>` = Paket -> `"<distName> <version>"`
6. In `finally`: wenn `archive`, `archiveArtifacts 'dist/*.tar.gz'` mit
   `allowEmptyArchive: true, fingerprint: true`; wenn `cleanup`, `cleanup()`.
   Reihenfolge: erst archivieren, dann aufraeumen.

| Argument | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `nexusUrl` | ja | -- | Basis-URL; fehlt sie, sofort `error` |
| `hostedRepo` | nein | `pypi-hosted` | HOSTED-Repo, nie die Group |
| `credentialsId` | nein | `nexus-pypi-deploy` | Username/Password-Credential |
| `packages` | nein | `''` | feste Paketliste; leer = Auto-Erkennung |
| `buildAll` | nein | `params.BUILD_ALL ?: false` | alles bauen |
| `skipUpload` | nein | `params.SKIP_UPLOAD ?: false` | Dry-Run |
| `base` | nein | berechnet | Diff-Basis; `buildAll` erzwingt leere Basis |
| `archive` | nein | `true` | `dist/*.tar.gz` am Ende archivieren |
| `cleanup` | nein | `true` | `dist/` und `.ci-lib/` am Ende entfernen |

Parameterfluss fuer `buildAll`/`skipUpload`: Argument, wenn im Map vorhanden
(auch `false` zaehlt als vorhanden); sonst `params.<NAME>`, wenn die Pipeline
den Parameter definiert; sonst `false`. Der Zugriff auf `params` laeuft ueber
ein `try`/`catch` um den Property-Zugriff `params` - schlaegt er fehl (keine
`parameters{}` in der Pipeline definiert), gibt es den Default. Grund fuer den
`try`/`catch`: in Jenkins-CPS (workflow-cps) ist `params` keine Eintragung im
Script-Binding, sondern eine `GlobalVariable`, die erst ueber den
`MissingPropertyException`-Fallback von `CpsScript.getProperty()` aufgeloest
wird - ohne `parameters{}` in der Pipeline schlaegt dieser Zugriff mit
`MissingPropertyException` fehl, statt `params` einfach leer zu liefern.
(Ein frueherer Entwurf pruefte zusaetzlich `Script.getBinding().hasVariable
('params')` als vorgelagerte Stufe - der Zweig war wirkungslos, weil `params`
nie im Script-Binding auftaucht, und `Script.getBinding()` ist im Sandbox
nicht freigegeben; er zwang die Library dadurch ohne Funktionsgewinn zu einer
trusted Installation und ist deshalb gestrichen (I-2 im Abschluss-Review).)
`call()` uebergibt `buildAll: params.BUILD_ALL, skipUpload: params.SKIP_UPLOAD`
explizit an `build()` - die Vollpipeline haengt damit nie von `paramOr()` ab.

Basis-Berechnung, wenn `base` fehlt: `buildAll ? '' :
(env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: git rev-parse HEAD~1 ?: '')` — wie heute.

Unbekannte Schluessel im Map fuehren zu `error` mit der Liste der erlaubten
Schluessel. (Uebernimmt damit den zurueckgestellten Minor-Befund M-3 fuer den
neuen Einstiegspunkt; der Config-Closure des Wrappers bleibt wie bisher.)

`keepBuilds` gibt es fuer `build()` nicht: `options {}` gehoert dem Aufrufer.

## Vollpipeline-Wrapper: `call(Closure)`

Bleibt als Declarative Pipeline mit `agent any`, `options` (inkl. `keepBuilds`),
`parameters` (`BUILD_ALL`, `SKIP_UPLOAD`) und `post` wie heute. Die beiden
Stages werden zu einer Stage `Build`, deren `script {}` genau
`pyMonorepo.build(nexusUrl: cfg.nexusUrl, hostedRepo: cfg.hostedRepo,
credentialsId: cfg.credentialsId, packages: cfg.packages, archive: false,
cleanup: false)` aufruft. Archivieren und Aufraeumen bleiben im `post`-Block
(`always` / `cleanup`), damit sie auch bei einem Abbruch innerhalb von `build()`
laufen — Verhalten identisch zu heute.

Die Config-Closure (`nexusUrl`, `hostedRepo`, `credentialsId`, `packages`,
`keepBuilds`) und `examples/Jenkinsfile` bleiben unveraendert. Bestehende
Nutzer der Vollpipeline merken nichts.

Bekannter, unveraenderter Punkt: `cfg.keepBuilds` im `options`-Block ist
weiterhin der einzige `cfg`-Zugriff innerhalb einer Declarative-Direktive und
bleibt erster Pruefpunkt beim ersten Jenkins-Lauf.

## Vorlagen und Doku

* `examples/Jenkinsfile` — Vollpipeline, unveraendert.
* `examples/Jenkinsfile.embedded` — **neu**: eine bestehende Declarative
  Pipeline mit eigenen Stages (z. B. `Lint`, `Test`), eigenem `parameters {}`
  und `post {}`; eine Stage `Pakete` ruft in `script {}`
  `pyMonorepo.build(nexusUrl: ..., hostedRepo: ...)`.
* `examples/Jenkinsfile.steps` — **neu**: dieselbe Pipeline mit Einzel-Steps
  (`install`, `changedPackages`, eigene Schleife, `publish`, `cleanup` im
  `post`), fuer Repos, die abweichen muessen.
* `README-ci.md`: neuer Abschnitt "Integration in eine bestehende Pipeline"
  (Composite zuerst, dann Einzel-Steps), Argument-Tabelle von `build()`,
  Step-Tabelle; der Abschnitt "Artefakte und Aufraeumen" erklaert `archive`/
  `cleanup` und wann man sie auf `false` setzt. Aufbau-Liste um die beiden
  neuen Vorlagen ergaenzen.

## Tests

`vars/pyMonorepo.groovy` bleibt lokal unausfuehrbar (kein Groovy, keine JRE).
Die Strukturtests in `test/run-tests.sh` werden angepasst, nicht abgeschwaecht:

Bleiben (angepasst an die neue Struktur):
* Skriptliste in `install()` == vorhandene Skripte
* `libraryResource`-Pfad `de/firma/ci`, `encoding: 'UTF-8'`
* Zielverzeichnis mit fuehrendem Punkt
* Genau **eine** `sh`-Aufrufstelle je Skript (`changed-packages.sh` 1,
  `build-sdist.sh` 1, `sdist-meta.sh` 1, `publish-pypi.sh` 1) — weil die Steps
  Single-Source sind, sinkt die Zahl fuer `sdist-meta.sh` von 2 auf 1
* Klammern ausgeglichen (Kommentare ausgenommen)

Neu:
* Jede oeffentliche Methode existiert: `call`, `install`, `changedPackages`
  (2 Ueberladungen), `buildSdist`, `meta`, `publish`, `build`, `cleanup`
* Der Rumpf von `build()` enthaelt kein `pipeline {`
* **Kein** `sh`-Aufruf im ganzen File enthaelt `${` innerhalb des
  Script-Strings — maschineller Beleg der Injection-Disziplin. Umsetzung:
  alle `sh(`/`sh '`-Vorkommen extrahieren und auf `\$\{` pruefen.
* Keine Methode hat einen Default-Parameter (`grep -E '\(\s*\w+ \w+ = '`)
* `meta()` enthaelt die Whitelist `['name', 'version']`
* Jede Mutation, die ein Test fangen soll, wird beim Schreiben des Tests
  einmal angewendet und der Rotlauf gezeigt (wie bisher)

Die Shell-Skripte und ihre Tests sind von diesem Umbau nicht betroffen.

## Migration / Kompatibilitaet

* Vollpipeline-Nutzer: keine Aenderung noetig.
* Bestehende Pipeline: `@Library('ci-shared@...') _` oben, eine Stage mit
  `script { pyMonorepo.build(nexusUrl: ..., hostedRepo: ...) }`, `.ci-lib/`
  in `.gitignore`. Wenn die Pipeline eigene `BUILD_ALL`/`SKIP_UPLOAD`-Parameter
  hat, werden sie automatisch beruecksichtigt; sonst `buildAll:`/`skipUpload:`
  als Argument.
* Agent-Voraussetzungen unveraendert (siehe README).

## Nicht verifizierbar (wie bisher)

Groovy-Syntax, Declarative-AST-Transformation, CPS-Verhalten der neuen
Methoden, der `params`-Property-Zugriff in beiden Pipeline-Arten, `parallel`
mit `stage()` innerhalb eines `script {}`-Blocks einer fremden Stage. Erster
echter Pruefpunkt bleibt ein Jenkins-Lauf; die Reihenfolge aus dem Plan-Nachtrag
gilt weiter, ergaenzt um: (0) Laedt das Var mit `call()` **und** benannten
Methoden? (7) Laeuft `build()` eingebettet in einer fremden Stage, inklusive
verschachtelter `stage(pkg)`-Aufrufe im `parallel`?
