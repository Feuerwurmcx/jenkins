# pyMonorepo: Jenkins Shared Library statt direkter sh-Aufrufe

Datum: 2026-09-03

## Problem

Der `Jenkinsfile` ruft die Build-Skripte direkt als `bash ci/<skript>.sh` auf.
Jedes Monorepo, das so gebaut werden soll, braucht damit eine eigene Kopie des
`ci/`-Ordners und eine eigene Kopie der Pipelinelogik. Aenderungen an Build oder
Upload muessen in jedem Repo einzeln nachgezogen werden.

Der Bestand hat ausserdem drei Altlasten, die dabei mit aufgeraeumt werden:

* `ci/changed-packages.sh` wird vom `Jenkinsfile` aufgerufen, existiert aber nicht.
* `pack.sh`, `upload-nexus.sh`, `version-of.sh` sind die aeltere RAW/tar.gz-Generation
  und werden vom `Jenkinsfile` nicht mehr aufgerufen.
* `README-ci.md` beschreibt durchgaengig diese alte RAW-Generation (`NEXUS_REPO`,
  Credential `nexus-raw-deploy`, Ablage als `<paket>/<version>/...`), nicht das,
  was der `Jenkinsfile` tatsaechlich tut.

## Ziel

Die Skripte und die Pipeline kommen aus einer Jenkins Shared Library. Ein
Monorepo braucht dann nur noch einen `Jenkinsfile` mit wenigen Zeilen Konfiguration
und keinen `ci/`-Ordner mehr.

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| Wo liegen die `.sh`? | In der Library unter `resources/`, zur Laufzeit per `libraryResource` + `writeFile` auf den Agent geschrieben |
| Wie gross ist der Schnitt? | Die komplette Pipeline liegt in `vars/pyMonorepo.groovy`; der Monorepo-`Jenkinsfile` konfiguriert nur |
| Welche Skripte? | Die vier PyPI-Skripte. Die RAW-Generation wird geloescht, das README auf den PyPI-Stand gebracht |

Bewusst *nicht* gemacht (YAGNI): kein `publish: 'pypi' | 'raw'`-Schalter, keine
oeffentlichen Einzel-Steps neben der Standard-Pipeline, keine Groovy-Nachbauten
der Shell-Logik.

## Zielstruktur des Repos

    vars/pyMonorepo.groovy                 die Pipeline
    resources/de/ba/pymonorepo/
        changed-packages.sh                neu, nach bisheriger README-Spec
        build-sdist.sh                     verschoben, Logik unveraendert
        sdist-meta.sh                      verschoben, Logik unveraendert
        publish-pypi.sh                    verschoben, Logik unveraendert
    examples/Jenkinsfile                   Vorlage fuer ein Monorepo
    test/fixture/                          Mini-Monorepo fuer die Tests
    test/run-tests.sh                      Testtreiber
    .gitattributes                         resources/**/*.sh text eol=lf
    README-ci.md                           auf PyPI-Stand gebracht

An den drei verschobenen Skripten aendert sich die Logik nicht. Angepasst werden
nur die Kopfkommentare: die Aufrufbeispiele nennen dort heute `ci/<skript>.sh`,
ein Pfad, den es nach der Migration nicht mehr gibt.

Der bisherige `Jenkinsfile` an der Wurzel wandert nach `examples/`. An der Wurzel
wuerde ihn ein Multibranch-Job als CI *dieses* Repos ausfuehren, was er nicht ist.

Geloescht werden `pack.sh`, `upload-nexus.sh`, `version-of.sh`.

## Mechanik: wie die Skripte auf den Agent kommen

```groovy
private String materializeScripts() {
    String dir = "${env.WORKSPACE_TMP ?: env.WORKSPACE}/pymonorepo-scripts"
    ['changed-packages.sh', 'build-sdist.sh', 'sdist-meta.sh', 'publish-pypi.sh'].each { n ->
        writeFile file: "${dir}/${n}", text: libraryResource("de/ba/pymonorepo/${n}")
    }
    return dir
}
```

Drei Punkte, die dabei zaehlen:

**Ziel ist `WORKSPACE_TMP`, nicht der Checkout.** `changed-packages.sh` erkennt
Pakete an Top-Level-Ordnern und wertet `git diff` aus. Ein Skriptordner im
Checkout waere Rauschen in genau der Logik, die er auswertet. Das
Arbeitsverzeichnis der `sh`-Aufrufe bleibt der Checkout; gerufen wird ueber den
absoluten Pfad aus `materializeScripts()`.

**Das Ausfuehrbar-Bit entfaellt als Problem.** `writeFile` setzt es nicht, aber der
Aufruf bleibt `bash <pfad>` -- dieselbe Begruendung, die heute schon im README
steht. Der Abschnitt „Troubleshooting: Permission denied" wird damit
gegenstandslos und entfaellt.

**`.gitattributes` mit `eol=lf`.** Sonst schleppt ein Windows-Checkout der
Library CRLF in den Shebang und der Agent scheitert mit
`bad interpreter: /usr/bin/env bash^M`.

Die Skripte werden einmal in der Setup-Stage geschrieben; der zurueckgegebene Pfad
wird von den parallelen Branches der Pack-&-Publish-Stage mitbenutzt.

## API

```groovy
@Library('py-monorepo') _

pyMonorepo {
    nexusUrl   = 'https://nexus.example.com'
    hostedRepo = 'pypi-hosted'
}
```

| Schluessel | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `nexusUrl` | ja | -- | Basis-URL der Nexus-Instanz |
| `hostedRepo` | nein | `pypi-hosted` | HOSTED-Repo, nie die Group |
| `credentialsId` | nein | `nexus-pypi-deploy` | Username/Password-Credential in Jenkins |
| `packages` | nein | `''` | Feste Paketliste; leer heisst Auto-Erkennung |
| `keepBuilds` | nein | `30` | `logRotator(numToKeepStr:)` |

Fehlt `nexusUrl`, bricht die Pipeline sofort mit klarer Meldung ab, statt erst
beim Upload.

`packages` wird als Umgebungsvariable `PACKAGES` an `changed-packages.sh`
durchgereicht, ebenfalls per `withEnv`.

Die Konfiguration kommt ueber eine Closure mit
`resolveStrategy = DELEGATE_FIRST` und einer Map als Delegate, ausgewertet in
`call()` vor dem `pipeline`-Block.

## Pipeline

Stages, Parameter und `post` bleiben inhaltlich wie im heutigen `Jenkinsfile`:

* Parameter `BUILD_ALL` und `SKIP_UPLOAD` unveraendert.
* Stage *Setup*: Skripte materialisieren, Basis-Commit bestimmen
  (`GIT_PREVIOUS_SUCCESSFUL_COMMIT`, sonst `HEAD~1`, sonst leer),
  `changed-packages.sh` aufrufen, `env.CHANGED` und `currentBuild.description` setzen.
* Stage *Pack & Publish*: `parallel` pro Paket, je `build-sdist.sh` ->
  `sdist-meta.sh` (name, version) -> `publish-pypi.sh`.
* `post`: `archiveArtifacts` auf `dist/*.tar.gz`, Cleanup von `dist` und dem
  Skriptordner.

Eine Abweichung zum Bestand: die Nexus-Werte gehen nicht ueber einen
`environment`-Block, sondern per `withEnv` direkt um die Schritte, die sie
brauchen. Das ist dieselbe Ueberlegung, aus der schon heute `credentials()` im
`environment` bewusst vermieden wird, konsequent auf die uebrigen Werte
ausgedehnt; ausserdem umgeht es die Einschraenkungen, die `environment` bei
Declarative-in-Shared-Library hat. `withCredentials` um den Upload bleibt
unveraendert, inklusive der Eigenschaft, dass das Secret nicht in den
Groovy-String interpoliert wird.

## changed-packages.sh

Neu zu schreiben, Verhalten nach der bisherigen README-Beschreibung:

    changed-packages.sh <base>          # gibt Paketnamen zeilenweise auf stdout

* Ein Paket ist ein Top-Level-Ordner mit `pyproject.toml`, `setup.py` oder `__init__.py`.
* `PACKAGES="a b c"` ersetzt die Auto-Erkennung durch eine feste Liste.
* Ausgegeben wird die Schnittmenge aus „ist ein Paket" und „liegt im `git diff` seit `<base>`".
* Alles bauen, wenn: `<base>` leer oder kein gueltiger Commit; oder wenn `ci/`
  bzw. `Jenkinsfile` geaendert wurden.

Der letzte Sonderfall bleibt so erhalten, obwohl `ci/` in Monorepos kuenftig
verschwindet: ein Repo kann waehrend der Migration noch einen `ci/`-Ordner haben,
und eine Aenderung am `Jenkinsfile` (also an der Konfiguration der Library) soll
weiterhin alles neu bauen.

## Tests

Testtreiber `test/run-tests.sh`, ohne Netzwerk lauffaehig. Nicht abgedeckte Faelle
meldet er ausdruecklich als SKIP -- er soll nicht gruen aussehen, wo nichts
geprueft wurde.

| Pruefung | Abgedeckt |
|---|---|
| `bash -n` auf allen vier Skripten | ja |
| `changed-packages.sh` end-to-end gegen ein Fixture-Git-Repo | ja, braucht nur git |
| `sdist-meta.sh` gegen ein handgebautes `.tar.gz` mit `PKG-INFO` | ja, ohne Python |
| `build-sdist.sh` Guard-Clauses (kein Verzeichnis, keine Metadaten) | ja |
| `build-sdist.sh` Happy Path | SKIP -- `setuptools`/`build` fehlen lokal |
| `publish-pypi.sh` Guard-Clauses (fehlende Env-Variablen) | ja |
| `publish-pypi.sh` echter Upload | nein, und soll auch nicht |
| `pyMonorepo.groovy` Syntaxpruefung | nein -- kein `groovy`/`groovyc` lokal |

`vars/pyMonorepo.groovy` bleibt damit unverifiziert. Das ist die reale Schwaeche
dieses Umbaus und der Grund, die Pipelinelogik duenn zu halten und die Substanz
in den Skripten zu lassen: was in `.sh` steckt, ist lokal testbar, was in Groovy
steckt, erst auf einem Jenkins.

## Migration eines Monorepos

1. In Jenkins die Library unter dem Namen `py-monorepo` registrieren
   (Manage Jenkins -> System -> Global Pipeline Libraries).
2. Im Monorepo den `Jenkinsfile` durch die Vorlage aus `examples/` ersetzen.
3. `ci/` im Monorepo loeschen.
4. Einmal mit `SKIP_UPLOAD` bauen und die Paketliste im Log gegen den alten Build
   vergleichen.

## Was am README-ci.md konkret zu aendern ist

* Dateiliste: `ci/*.sh` raus, Library-Struktur rein.
* Einrichtung: RAW-Repo -> PyPI-hosted-Repo, Credential-ID `nexus-raw-deploy` ->
  `nexus-pypi-deploy`, plus das Registrieren der Library in Jenkins.
* `NEXUS_REPO` -> `NEXUS_PYPI_HOSTED` durchgaengig.
* Ablageschema: der Abschnitt `<paket>/<version>/<paket>-<version>.tar.gz` gilt
  nur fuer RAW und entfaellt; PyPI-hosted legt selbst ab.
* Die Abschnitte „Woher die Version kommt" (beschreibt `version-of.sh`) und
  „Doppelte Versionen" (beschreibt den HEAD-Check in `upload-nexus.sh`) entfallen.
  Ersatz: die Version kommt aus der `PKG-INFO` der gebauten sdist, und doppelte
  Versionen erkennt `publish-pypi.sh` am 400 des Repos (Exit-Code 2).
* „Lokal testen" auf die vier verbleibenden Skripte umschreiben.
* „Troubleshooting: Permission denied" entfaellt (siehe Mechanik-Abschnitt).
