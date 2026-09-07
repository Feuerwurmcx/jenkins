# ci-shared: Jenkins Shared Library fuer Python-Monorepos

Ermittelt die geaenderten Pakete eines Monorepos, baut je eine sdist und laedt
sie in ein Nexus-PyPI-**hosted**-Repo.

## Aufbau

    vars/pyMonorepo.groovy                 die Pipeline
    resources/de/firma/ci/
        changed-packages.sh                welche Top-Level-Ordner haben sich geaendert
        build-sdist.sh                     ein Ordner -> dist/<name>-<version>.tar.gz (echte sdist)
        sdist-meta.sh                      Name/Version aus der PKG-INFO der sdist
        publish-pypi.sh                    curl-Upload ins PyPI-hosted-Repo (Nexus-REST-API)
    examples/Jenkinsfile                   Vorlage fuer die Wurzel eines Monorepos
    examples/Jenkinsfile.embedded          bestehende Pipeline + eine Stage mit pyMonorepo.build()
    examples/Jenkinsfile.steps             bestehende Pipeline mit Einzel-Steps
    test/run-tests.sh                      Testtreiber

Die vier Skripte sind eigenstaendig und lokal testbar; die Pipeline ruft nur
auf. Sie liegen in `resources/` und werden zur Laufzeit per `libraryResource`
auf den Agent geschrieben - ein Monorepo braucht deshalb keinen `ci/`-Ordner.

## Voraussetzungen auf dem Agent

Die Skripte rufen nichts auf, was nicht ohnehin schon da sein muss - aber
folgendes muss auf dem Jenkins-Agent installiert sein, bevor der erste Build
laeuft:

* `bash` (die Skripte selbst; `/bin/bash` reicht, auch die alte 3.2 von macOS)
* `git` (`changed-packages.sh`)
* `tar` (`build-sdist.sh`, `sdist-meta.sh`)
* `curl` (`publish-pypi.sh`, Repo-Typ-Check, Simple-Index-Abfrage vor dem
  Upload und der Upload selbst - alle drei gegen die Nexus-REST-API)
* `python3` mit `build` (`python3 -m pip install --user build`) oder ersatzweise
  `setuptools` (`build-sdist.sh` faellt sonst auf `setup.py sdist` zurueck);
  `publish-pypi.sh` braucht ausserdem nacktes `python3` (Stdlib genuegt) fuer
  den Repo-Typ-Check

Ausdruecklich **nicht** noetig ist `twine`: der Upload laeuft per `curl` gegen
die Nexus-REST-Components-API.

## Einmalige Einrichtung

1. Nexus: PyPI-Repo vom Typ **hosted** anlegen. Group-Repos nehmen keine
   Uploads an, die sind nur zum Lesen da
   (`pip install -i .../repository/<group>/simple/`).
2. Jenkins: Credential vom Typ *Username with password* mit der ID
   `nexus-pypi-deploy`.
3. Jenkins: dieses Repo unter dem Namen `ci-shared` als Pipeline Library
   eintragen. Als Global Pipeline Library (Manage Jenkins -> System ->
   Global Pipeline Libraries) empfohlen, wenn mehrere Teams sie nutzen sollen -
   zwingend ist das nicht mehr: die Library kommt ohne `binding`-Zugriff aus
   und laeuft auch als folder-scoped, sandboxed Library (`Folder Configuration
   -> Pipeline Libraries`).
4. Im Monorepo `examples/Jenkinsfile` als `Jenkinsfile` in die Wurzel legen,
   `nexusUrl` sowie `hostedRepo` anpassen und `.ci-lib/` in die `.gitignore`
   aufnehmen - dorthin schreibt die Library die Skripte bei jedem Build,
   auch beim allerersten.
5. Job als *Multibranch Pipeline* oder *Pipeline from SCM* anlegen - wichtig,
   damit `GIT_PREVIOUS_SUCCESSFUL_COMMIT` gesetzt wird.

`examples/Jenkinsfile` referenziert `@Library('ci-shared@v1.0.0')`. Dieses
Repo hat vor dem ersten produktiven Einsatz noch keinen Tag `v1.0.0` - vor der
ersten Nutzung entweder einen passenden Tag auf der Library setzen oder die
Versionsangabe im Jenkinsfile an das anpassen, was tatsaechlich existiert
(z. B. einen Branch-Namen statt eines Tags).

## Konfiguration

| Schluessel | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `nexusUrl` | ja | -- | Basis-URL der Nexus-Instanz |
| `hostedRepo` | nein | `pypi-hosted` | HOSTED-Repo, nie die Group |
| `credentialsId` | nein | `nexus-pypi-deploy` | Username/Password-Credential |
| `packages` | nein | `''` | Feste Paketliste; leer heisst Auto-Erkennung |
| `rootPackage` | nein | `false` | Das Repo IST ein Paket (Metadaten in der Wurzel) |
| `keepBuilds` | nein | `30` | wie viele Builds aufgehoben werden |

Fehlt `nexusUrl`, bricht die Pipeline sofort ab statt erst beim Upload.

## Integration in eine bestehende Pipeline

Die Vollpipeline `pyMonorepo { ... }` ersetzt den ganzen Jenkinsfile. Wer schon
eine Pipeline mit eigenen Stages hat, bindet die Library stattdessen in einer
Stage ein — ein Declarative `pipeline {}` laesst sich nicht in ein anderes
einbetten, ein Step schon.

### Voraussetzungen an die Stage

`build()` (und die Einzel-Steps) laufen im Workspace der aufrufenden Stage,
nicht in einem eigenen. Das bringt drei Voraussetzungen mit, die eine
Vollpipeline (`agent any` mit implizitem Checkout) automatisch erfuellte,
eine eingebettete Pipeline aber nicht zwingend:

* Die Stage braucht einen Agent mit Workspace - `agent none` auf oberster
  Ebene mit einem `agent`-losen `script {}` funktioniert nicht.
* Der Workspace braucht einen Git-Checkout des Monorepos, sonst scheitert
  `changedPackages()`/`build()` an `git diff`. Bei `options {
  skipDefaultCheckout() }` vorher explizit `checkout scm` aufrufen.
* Ein `shallow clone` (wenig oder keine History) ist kein harter Fehler, fuehrt
  aber dazu, dass `changed-packages.sh` den Basis-Commit nicht findet und auf
  "alles bauen" zurueckfaellt - bei jedem Build.

**`dist/`-Konflikt:** `build()` baut nach `dist/` (wie `python -m build`) und
`cleanup()` entfernt danach die eigenen `dist/*.tar.gz` (siehe "Artefakte und
Aufraeumen"). Baut die eigene Pipeline selbst etwas nach `dist/` (webpack,
rollup, vite, `python -m build` fuer ein anderes Paket, Gradle
`distribution`), reicht das inzwischen aus, um Kollisionen zu vermeiden -
`cleanup()` loescht das Verzeichnis nicht mehr komplett. Wer trotzdem auf
Nummer sicher gehen will (z. B. bei einem eigenen, exotischen Aufraeum-Schritt
gegen `dist/`), setzt `cleanup: false` und ruft `pyMonorepo.cleanup()` selbst
an der gewuenschten Stelle auf.

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
| `rootPackage` | nein | `params.ROOT_PACKAGE`, sonst `false` | Repo ist selbst ein Paket -> Liste ist `.` |
| `buildAll` | nein | `params.BUILD_ALL`, sonst `false` | alles bauen |
| `skipUpload` | nein | `params.SKIP_UPLOAD`, sonst `false` | Dry-Run |
| `base` | nein | berechnet, bei `buildAll: true` immer `''` | Diff-Basis (`GIT_PREVIOUS_SUCCESSFUL_COMMIT`, sonst `HEAD~1`); `''` = alles bauen |
| `archive` | nein | `true` | `dist/*.tar.gz` am Ende archivieren |
| `cleanup` | nein | `true` | `dist/` und `.ci-lib/` am Ende entfernen |

`buildAll`/`skipUpload`: ein uebergebenes Argument gewinnt. Fehlt es, liest
`build()` `params.BUILD_ALL`/`params.SKIP_UPLOAD`, falls die Pipeline solche
Parameter definiert; sonst `false`. Unbekannte Argumente sind ein Fehler.

`buildAll`/`skipUpload`/`archive`/`cleanup` akzeptieren sowohl Boolean als
auch String: ein String wird geparst (`'true'`/`'false'`, Gross-/
Kleinschreibung egal), alles ausser `true`/`'true'` gilt als falsch. Damit
zaehlt ein `string`-Parameter einer fremden Pipeline mit dem Wert `'false'`
nicht faelschlich als wahr (Groovy-Truthiness wuerde jeden nicht-leeren
String als `true` werten).

`build()` ueberschreibt `currentBuild.description`: bei leerer Paketliste
einmalig auf `'keine Paketänderungen'`, sonst zuerst auf die Paketliste
(`"<n> Paket(e): ..."`) und am Ende auf die Versionsliste. Eine
einbettende Pipeline, die die Beschreibung selbst setzt, sollte das
danach tun.

`archive`/`cleanup` laufen im `finally` des Steps: ein Abort
(`FlowInterruptedException`, eine Unterklasse von `InterruptedException`)
wird dabei weitergeworfen statt verschluckt, andere Fehler beim Aufraeumen
werden nur geloggt. Wer maximale Robustheit bei Abbruechen will, setzt
`archive`/`cleanup` auf `false` und uebernimmt Archivieren/Aufraeumen im
eigenen `post` — genau so macht es `call()` (die Vollpipeline) selbst: es
ruft intern `build(..., archive: false, cleanup: false)` und archiviert/raeumt
im eigenen `post`-Block auf. Das Einzel-Steps-Beispiel
`examples/Jenkinsfile.steps` folgt demselben Muster ganz ohne `build()`.

Rueckgabe: `Map` Paket -> `"<name> <version>"`; leer, wenn nichts geaendert war.

### Einzel-Steps

Fuer Pipelines, die abweichen muessen (sequentiell, Upload nur auf bestimmten
Branches, eigene Stage je Paket):

| Step | Rueckgabe | Bedeutung |
|---|---|---|
| `pyMonorepo.install()` | Pfad | Skripte nach `.ci-lib/` schreiben; **zuerst** aufrufen |
| `pyMonorepo.changedPackages(base)` | `List` | geaenderte Pakete; leere Basis = alle |
| `pyMonorepo.changedPackages(base, packages)` | `List` | mit fester Paketliste |
| `pyMonorepo.changedPackages(base, packages, rootPackage)` | `List` | `rootPackage: true` -> Liste ist `.` |
| `pyMonorepo.buildSdist(pkg)` | Archivpfad | sdist bauen |
| `pyMonorepo.meta(archive, 'name'\|'version')` | String | aus der PKG-INFO |
| `pyMonorepo.publish(archive:, nexusUrl:, hostedRepo:, credentialsId:)` | -- | Upload |
| `pyMonorepo.cleanup()` | -- | eigene sdists aus `dist/` und `.ci-lib/` entfernen |

`changedPackages()`, `buildSdist()`, `meta()` und `publish()` brechen mit
klarer Meldung ab, wenn `install()` nicht vorher aufgerufen wurde.
`cleanup()` ist die Ausnahme: es ist idempotent und raeumt auch auf, wenn
`install()` nie lief. `cleanup()` setzt dabei auch `env.CI_LIB_DIR` zurueck -
ein Einzel-Step **nach** `cleanup()` in derselben Pipeline verlangt deshalb
wieder ein vorheriges `install()`, sonst bricht er mit derselben Meldung ab
wie ohne jedes `install()`. Alle Steps funktionieren in Declarative (`script {}`)
und Scripted Pipelines. Vollstaendiges Beispiel: `examples/Jenkinsfile.steps`.
Das Beispiel nutzt `env.BRANCH_NAME` (Upload nur auf main) und
`env.GIT_PREVIOUS_SUCCESSFUL_COMMIT` (Diff-Basis); beide sind nur in
Multibranch-Pipeline- und "Pipeline from SCM"-Jobs gesetzt, in einem
normalen Pipeline-Job muss man sie durch eine eigene Bedingung ersetzen,
sonst wird nie hochgeladen.

Auch hier gehoert `.ci-lib/` in die `.gitignore` des Monorepos.

## Woher die Version kommt

Aus der `PKG-INFO` der **gebauten** sdist, nicht aus dem Ordnernamen und nicht
aus dem Dateinamen. Beides kann abweichen, weil setuptools normalisiert:

    Ordner  alpha    name="Mein.Tolles_Paket"  ->  mein_tolles_paket-...
    Version 1.0-1                              ->  1.0.post1  (PEP 440)

Ausserdem duerfen Paketnamen selbst Bindestriche enthalten - den Dateinamen zu
zerlegen waere also mehrdeutig. `build-sdist.sh` gibt den tatsaechlichen Pfad
aus, `sdist-meta.sh` liest Name und Version aus der `PKG-INFO`.

## Doppelte Versionen

Wird dieselbe Version erneut gebaut - ein Re-Run, oder ein Monorepo-Build, in
dem sich nur eines von mehreren Paketen geaendert hat -, laedt
`publish-pypi.sh` nicht erneut hoch. Vor dem Upload fragt es den Simple-Index
des Ziel-Repos (`/repository/<repo>/simple/<name>/`, dieselbe API, die auch pip
liest). `<name>` ist dabei PEP-503-normalisiert, nicht der rohe Paketname: alles
klein, und `-`, `_` und `.` in beliebiger Wiederholung zu einem einzelnen `-`.
Aus `Mein.Tolles_Paket` wird so `mein-tolles-paket` fuer die Index-URL - eine
andere Normalisierung als die setuptools-Normalisierung im Dateinamen weiter
oben (`mein_tolles_paket-...`, mit Unterstrich).

Ist der Dateiname dort gelistet, meldet das Skript

    SKIP: mein_paket-1.2.3.tar.gz liegt bereits in pypi-hosted

und endet mit Exit-Code 0. Verglichen wird der exakte Dateiname, nicht als
Teilzeichenkette - sonst wuerde ein gelistetes `...tar.gz.asc` faelschlich als
Treffer zaehlen.

Die Pruefung ist eine Abkuerzung, kein Gate. Laesst sich der Index nicht
abfragen - fehlende Rechte, unerwarteter Status, curl scheitert - oder laesst
sich der Paketname selbst nicht aus der sdist lesen, wird nur gewarnt und
normal hochgeladen. Lehnt Nexus den Upload dann mit HTTP 400 und
`already exists` bzw. `does not allow updating` ab, gilt dasselbe: Datei liegt
im Repo, Exit-Code 0, `SKIP`-Meldung. Das deckt auch den Fall ab, dass zwei
Builds gleichzeitig dieselbe Version hochladen wollen.

**Damit faellt ein vergessener Version-Bump nicht mehr auf.** Der Build wird
gruen, im Repo bleibt die alte Version liegen. Das ist der Preis dafuer, dass
ein Re-Run keinen roten Build erzeugt; wer den Bump erzwingen will, prueft die
Version im Merge-Request statt im Build.

Andere 400er (kein Duplikat) werden mit Status und Body ausgegeben und enden
mit Exit-Code 1.

`publish-pypi.sh` postet dabei per `curl` gegen
`{NEXUS_URL}/service/rest/v1/components?repository={NEXUS_PYPI_HOSTED}` - die
Nexus-Components-API. Das ist nicht dieselbe URL, unter der Nexus die Datei
hinterher zeigt (`.../repository/<repo>/packages/<name>/<version>/<datei>`):
diesen Ablagepfad vergibt Nexus selbst aus Name und Version, die es aus der
`PKG-INFO` der sdist liest - wir schicken nur die Datei, keinen Zielpfad. Mit
twine war das nicht anders: twine postete ebenfalls gegen die Repo-Wurzel,
nicht gegen `/packages/`.

Bricht der Upload mit `curl: (3) URL rejected: Malformed input to a URL
function` ab, steckt ein Leerzeichen, ein Tabulator oder ein Carriage Return in
`nexusUrl` oder `hostedRepo` - meist ein CR aus einem CRLF-Editor oder ein
uebersehenes Leerzeichen in der Jenkinsfile-Konfiguration. `publish-pypi.sh`
faengt das inzwischen vorab ab und nennt die betroffene Variable samt Position,
bevor curl ueberhaupt laeuft. Sichtbar machen laesst es sich mit:

    printf '%s' "$NEXUS_URL" | od -c | head -3

`publish-pypi.sh` prueft ausserdem vorab ueber die Nexus-REST-API, ob
`NEXUS_PYPI_HOSTED` wirklich ein hosted-PyPI-Repo ist (Exit 3 bei group, bei
proxy und bei einem hosted-Repo, das kein PyPI-Format hat). Ist die API nicht
erreichbar oder fehlen die Rechte, wird nur gewarnt. Abschalten mit
`SKIP_REPO_CHECK=1`.

**Diese beiden Abkuerzungen sind gekoppelt:** die Simple-Index-Vorabpruefung
weiter oben laeuft nur, wenn dieser Repo-Typ-Check zuvor bestaetigt hat, dass
`NEXUS_PYPI_HOSTED` wirklich ein hosted-PyPI-Repo ist. Grund: zeigt
`NEXUS_PYPI_HOSTED` faelschlich auf ein Group-Repo, aggregiert dessen
Simple-Index die Member - auch einen PyPI-Proxy. Ein Treffer dort waere kein
verlaesslicher Beleg dafuer, dass die Datei im eigentlichen Ziel-Repo liegt,
und haette sonst zu einem stillen FALSCHEN Skip fuehren koennen: Build gruen,
nichts hochgeladen. Ist der Repo-Typ nicht bestaetigt - REST-API nicht
erreichbar, Repo in der API nicht gefunden, oder `SKIP_REPO_CHECK=1` - wird
deshalb auch die Simple-Index-Vorabpruefung uebersprungen; ein echtes
Duplikat faengt dann weiterhin der 400-Pfad ab, nur eine HTTP-Runde spaeter.

## Welche Pakete werden gebaut

`changed-packages.sh` erkennt Pakete als Top-Level-Ordner mit `pyproject.toml`,
`setup.py` oder `setup.cfg` - genau das, was `build-sdist.sh` auch bauen kann.
Ein Top-Level-Ordner mit nur einer `__init__.py` (z. B. `tests/` oder
`scripts/` mit Testhelfern) zaehlt bewusst nicht als Paket. Feste Liste
stattdessen:

    packages = 'paket1 paket2'                                        // im Jenkinsfile
    PACKAGES="paket1 paket2" bash resources/de/firma/ci/changed-packages.sh <base>     # lokal

Manche Repos sind selbst ein einziges Paket: die `pyproject.toml` liegt in der
Repo-Wurzel, der Quellcode unter `src/`. Dort gibt es keinen Top-Level-
Paketordner, und die Ordnersuche findet nichts. Solche Repos sagen es
ausdruecklich:

    pyMonorepo { nexusUrl = '...'; rootPackage = true }          // Vollpipeline
    pyMonorepo.build(nexusUrl: '...', rootPackage: true)         // Composite-Step
    pyMonorepo.changedPackages(base, '', true)                   // Einzel-Step
    ROOT_PACKAGE=true bash resources/de/firma/ci/changed-packages.sh <base>   # lokal

Dann ist die Paketliste genau `.`, und **jede** geaenderte Datei zaehlt als
Aenderung an diesem Paket. Im Build-Log heisst die Stage `Wurzelpaket`.
`packages = '.'` ist gleichbedeutend und ebenfalls erlaubt.

**Warum ein Schalter und keine Erkennung?** Ob eine Wurzel-`pyproject.toml`
ein Distributionspaket beschreibt oder nur Werkzeugkonfiguration
(`[tool.black]`, `[flake8]`) eines Monorepos ist, laesst sich ohne echten
TOML-Parser nicht zuverlaessig entscheiden - und beide Fehlrichtungen sind
teuer: ein Monorepo, das faelschlich als ein Paket gilt, verliert alle seine
Pakete; ein Einzelpaket, das nicht erkannt wird, baut gar nichts. Wer sein
Repo kennt, weiss die Antwort in einer Zeile.

Der Schalter kommt aus einer der drei Quellen, in dieser Reihenfolge: das
Argument `rootPackage` von `build()`, sonst der Build-Parameter
`ROOT_PACKAGE`, falls die einbettende Pipeline ihn hat, sonst `false`. Fuer
das Skript selbst ist es die Umgebungsvariable `ROOT_PACKAGE`. Als wahr gelten
`true`, `1`, `yes`, `on`, `ja` (Gross-/Kleinschreibung egal), als falsch
`false`, `0`, `no`, `off`, `nein` und der leere Wert. Ein anderer Wert bricht
mit Exit 2 ab, statt still als "aus" zu gelten - ein Tippfehler wie
`ROOT_PACKAGE=ture` wuerde sonst dazu fuehren, dass das Repo nichts baut und
der Build trotzdem gruen bleibt.

`rootPackage: true` zusammen mit einer anderen `packages`-Liste als `.` bricht
ebenfalls mit Exit 2 ab: das Repo ist entweder ein Paket oder eine Menge von
Paketordnern, nicht beides.

Wird gar kein Paket erkannt, meldet `changed-packages.sh` das auf stderr:

    HINWEIS: keine Paketordner gefunden - es wird nichts gebaut.
             ... Ist dieses Repo selbst EIN Paket (Metadaten in der Wurzel,
             Quellcode unter src/), dann rootPackage: true setzen ...

Der Build bleibt dabei gruen - ein Repo ohne Pakete ist kein Fehler -, aber die
Zeile steht im Log. Sie ist der erste Ort, an dem ein vergessenes
`rootPackage: true` auffaellt.

Gebaut wird die Schnittmenge aus "ist ein Paket" und "liegt im `git diff` seit
dem letzten erfolgreichen Build". Drei Sonderfaelle bauen absichtlich alles:

* kein gueltiger Basis-Commit (erster Build, neuer Branch, History gepruned)
* `ci/` oder `Jenkinsfile` wurden geaendert
* Build mit Parameter `BUILD_ALL`

Nur bauen, nicht hochladen: Build-Parameter `SKIP_UPLOAD`.

## Artefakte und Aufraeumen

Nach jedem Build - egal ob erfolgreich oder nicht - archiviert `pyMonorepo` im
`post`-Block `dist/*.tar.gz` mit Fingerprint (`archiveArtifacts ...
fingerprint: true`); `allowEmptyArchive: true` sorgt dafuer, dass ein Build
ohne Paketaenderungen (kein `dist/`) deswegen nicht als Fehler gilt. Die
sdists liegen danach im Artefakt-Tab des Builds, nicht mehr im Workspace: der
`cleanup`-Block entfernt anschliessend die selbst erzeugten `dist/*.tar.gz`
(und `dist/` selbst, aber nur, wenn dadurch nichts mehr darin liegt - eine
fremde Pipeline, die selbst nach `dist/` baut, behaelt ihr Artefakt, siehe
"Voraussetzungen an die Stage") sowie das Verzeichnis, in das die Skripte zur
Laufzeit geschrieben wurden (`.ci-lib/`, siehe `CI_LIB_DIR`). Mehr raeumt der
`cleanup`-Block nicht weg - es gibt weder `cleanWs()` noch `deleteDir()`. Der
uebrige Workspace bleibt zwischen Builds liegen: der Checkout, die
Paketordner und Build-Nebenprodukte wie `*.egg-info` sind auch nach dem Build
noch da.

Eingebettet per `build()` passiert dasselbe im `finally` des Steps (Argumente
`archive`/`cleanup`).

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

Das gilt nicht nur fuer das Secret: seit der `pyMonorepo`-Pipeline landet
ueberhaupt kein Laufzeitwert mehr per String-Interpolation in einem
`sh`-Aufruf. Paketname (`PKG`), Archivpfad (`ARCHIVE`) und Basis-Commit
(`BASE`) kommen alle per `withEnv` in die Umgebung; die `sh`-Skripte selbst
sind einfach gequotete String-Literale, die die Werte ueber `"$PKG"` &co.
lesen. Der Grund ist derselbe wie beim Secret, gilt hier aber zusaetzlich
gegen Befehlseinschleusung: `pkg` ist ein Top-Level-Ordnername aus dem
Monorepo und damit von jedem Branch aus kontrollierbar. Stuende er per
`"...${pkg}..."` im Groovy-String, koennte ein Ordnername wie
`x'; echo INJECTED >&2; '` einen zusaetzlichen Shell-Befehl einschleusen. Ueber
`withEnv` und ein gequotetes `"$PKG"` bleibt er ein einzelnes Argument, egal
welche Anfuehrungszeichen oder Sonderzeichen er enthaelt.

**3. argv.** Beide `curl`-Aufrufe in `publish-pypi.sh` – der Repo-Typ-Check und
der Upload – lesen die Zugangsdaten ueber `curl --config -` von stdin, nicht als
Kommandozeilenargument: sonst stuenden sie in der Prozessliste jedes Nutzers auf
dem Agent. `"` und `\` werden dabei escaped, weil sie im curl-Config-Format
Steuerzeichen sind. Der Testtreiber prueft beides.

Ein Zeilenumbruch in `NEXUS_USER`/`NEXUS_PASS` laesst sich im curl-Config-Format
nicht darstellen (ein Wert pro Zeile) - `publish-pypi.sh` lehnt das deshalb
vorab mit Exit-Code 1 und eigener Meldung ab, statt curl mit einer kaputten
Config abbrechen zu lassen. Ohne diese Pruefung wuerde curl beim Scheitern die
zweite Zeile woertlich in seine Fehlermeldung zitieren, und die landet ungekuerzt
im Build-Log - Jenkins maskiert dort nur das vollstaendige Secret, nicht ein
Fragment davon.

Wollt ihr Secrets ganz aus der Job-Konfiguration heraushalten, ist der naechste
Schritt ein Nexus-Token pro Team statt eines Deploy-Users, hinterlegt als
Jenkins-Credential mit Folder-Scope statt global.

## Migration eines bestehenden Monorepos

Zwei Faelle, je nachdem, ob das Monorepo schon eine eigene Pipeline hat.

### Monorepo ohne eigene Pipeline

1. Library in Jenkins als `ci-shared` registrieren (siehe Einrichtung).
2. `Jenkinsfile` durch die Vorlage aus `examples/` ersetzen.
3. `ci/` im Monorepo loeschen, `.ci-lib/` in die `.gitignore` aufnehmen -
   dorthin schreibt die Library die Skripte zur Laufzeit.
4. Einmal mit `SKIP_UPLOAD` bauen und die Paketliste im Log gegen den alten
   Build vergleichen.

### Monorepo mit bestehender Pipeline

Der Normalfall, fuer den dieser Umbau gemacht wurde - die eigene Pipeline
bleibt bestehen, nichts wird ersetzt:

1. Library in Jenkins als `ci-shared` registrieren (siehe Einrichtung).
2. Im bestehenden `Jenkinsfile` oben `@Library('ci-shared@v1.0.0') _`
   ergaenzen.
3. Eine Stage mit `script { pyMonorepo.build(nexusUrl: ..., hostedRepo: ...) }`
   einfuegen (siehe "Integration in eine bestehende Pipeline" oben).
4. `.ci-lib/` in die `.gitignore` aufnehmen - dorthin schreibt die Library die
   Skripte zur Laufzeit; ein eigener `ci/`-Ordner bleibt unangetastet und muss
   nicht geloescht werden.
5. Einmal mit `skipUpload: true` bauen und die Paketliste im Log gegen den
   bisherigen Weg gegenpruefen, bevor der Upload scharf geschaltet wird.

Eine fruehere Fassung der Vollpipeline setzte intern `env.CHANGED` mit der
Paketliste; dafuer gab es keinen externen Konsumenten, deshalb setzt
`pyMonorepo` das heute nicht mehr. Wer das bisher gelesen hat, muss es sich
selbst aus der Rueckgabe von `build()` bzw. `changedPackages()` bauen.
