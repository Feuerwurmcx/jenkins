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
* `curl` (`publish-pypi.sh`, Repo-Typ-Check gegen die Nexus-REST-API)
* `python3` mit `build` (`python3 -m pip install --user build`) oder ersatzweise
  `setuptools` (`build-sdist.sh` faellt sonst auf `setup.py sdist` zurueck)
* das Python-Modul `twine` (`python3 -m pip install --user twine`,
  `publish-pypi.sh`)

Fehlt `twine`, scheitert nicht die Einrichtung, sondern erst der erste
Upload-Schritt mit `No module named twine` - am besten vorher pruefen statt
das im ersten produktiven Build zu entdecken.

## Einmalige Einrichtung

1. Nexus: PyPI-Repo vom Typ **hosted** anlegen. Group-Repos nehmen keine
   Uploads an, die sind nur zum Lesen da
   (`pip install -i .../repository/<group>/simple/`).
2. Jenkins: Credential vom Typ *Username with password* mit der ID
   `nexus-pypi-deploy`.
3. Jenkins: Manage Jenkins -> System -> Global Pipeline Libraries, dieses Repo
   unter dem Namen `ci-shared` eintragen — nicht als folder-scoped bzw.
   sandboxed Library: `build()` liest `params` ueber `binding`, und das
   erfordert eine **trusted** Library.
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
| `keepBuilds` | nein | `30` | wie viele Builds aufgehoben werden |

Fehlt `nexusUrl`, bricht die Pipeline sofort ab statt erst beim Upload.

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

`buildAll`/`skipUpload`/`archive`/`cleanup` akzeptieren sowohl Boolean als
auch String: ein String wird geparst (`'true'`/`'false'`, Gross-/
Kleinschreibung egal), alles ausser `true`/`'true'` gilt als falsch. Damit
zaehlt ein `string`-Parameter einer fremden Pipeline mit dem Wert `'false'`
nicht faelschlich als wahr (Groovy-Truthiness wuerde jeden nicht-leeren
String als `true` werten).

`build()` ueberschreibt `currentBuild.description` (erst die Paketliste,
danach die Versionsliste). Eine einbettende Pipeline, die die Beschreibung
selbst setzt, sollte das danach tun.

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
| `pyMonorepo.buildSdist(pkg)` | Archivpfad | sdist bauen |
| `pyMonorepo.meta(archive, 'name'\|'version')` | String | aus der PKG-INFO |
| `pyMonorepo.publish(archive:, nexusUrl:, hostedRepo:, credentialsId:)` | -- | Upload |
| `pyMonorepo.cleanup()` | -- | `dist/` und `.ci-lib/` entfernen |

`changedPackages()`, `buildSdist()`, `meta()` und `publish()` brechen mit
klarer Meldung ab, wenn `install()` nicht vorher aufgerufen wurde.
`cleanup()` ist die Ausnahme: es ist idempotent und raeumt auch auf, wenn
`install()` nie lief. Alle Steps funktionieren in Declarative (`script {}`)
und Scripted Pipelines. Vollstaendiges Beispiel: `examples/Jenkinsfile.steps`.

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

Weil die Version aus dem Paket kommt, ist "zweimal dieselbe Version hochladen"
fast immer ein vergessener Version-Bump. Ein PyPI-hosted-Repo lehnt das mit 400
ab; `publish-pypi.sh` erkennt das und bricht mit Exit-Code 2 und klarer Meldung
ab, statt einen Infrastrukturfehler zu melden.

`publish-pypi.sh` prueft ausserdem vorab ueber die Nexus-REST-API, ob
`NEXUS_PYPI_HOSTED` wirklich ein hosted-PyPI-Repo ist (Exit 3 bei group, bei
proxy und bei einem hosted-Repo, das kein PyPI-Format hat). Ist die API nicht
erreichbar oder fehlen die Rechte, wird nur gewarnt. Abschalten mit
`SKIP_REPO_CHECK=1`.

## Welche Pakete werden gebaut

`changed-packages.sh` erkennt Pakete als Top-Level-Ordner mit `pyproject.toml`,
`setup.py` oder `setup.cfg` - genau das, was `build-sdist.sh` auch bauen kann.
Ein Top-Level-Ordner mit nur einer `__init__.py` (z. B. `tests/` oder
`scripts/` mit Testhelfern) zaehlt bewusst nicht als Paket. Feste Liste
stattdessen:

    packages = 'paket1 paket2'                                        // im Jenkinsfile
    PACKAGES="paket1 paket2" bash resources/de/firma/ci/changed-packages.sh <base>     # lokal

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
`cleanup`-Block loescht anschliessend `dist/` und das Verzeichnis, in das die
Skripte zur Laufzeit geschrieben wurden (`.ci-lib/`, siehe `CI_LIB_DIR`). Mehr
raeumt der `cleanup`-Block nicht weg - es gibt weder `cleanWs()` noch
`deleteDir()`. Der uebrige Workspace bleibt zwischen Builds liegen: der
Checkout, die Paketordner und Build-Nebenprodukte wie `*.egg-info` sind auch
nach dem Build noch da.

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

Eine fruehere Fassung der Vollpipeline setzte intern `env.CHANGED` mit der
Paketliste; dafuer gab es keinen externen Konsumenten, deshalb setzt
`pyMonorepo` das heute nicht mehr. Wer das bisher gelesen hat, muss es sich
selbst aus der Rueckgabe von `build()` bzw. `changedPackages()` bauen.
