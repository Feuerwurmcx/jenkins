# Jenkins-Build: 10 Python-Pakete -> tar.gz -> Nexus (raw)

## Dateien

    Jenkinsfile
    ci/changed-packages.sh   welche Top-Level-Ordner haben sich geändert
    ci/version-of.sh         Version eines Pakets aus setup.py / setup.cfg
    ci/pack.sh               ein Ordner -> dist/<paket>-<version>.tar.gz
    ci/upload-nexus.sh       curl PUT ins Nexus-RAW-Repo

Die vier Skripte sind eigenständig und lokal testbar – der Jenkinsfile ruft nur auf.

## Einmalige Einrichtung

1. Nexus: RAW-Repo anlegen (hosted, Deployment policy „Allow redeploy" nur wenn gewünscht).
2. Jenkins: Credential vom Typ *Username with password* mit der ID `nexus-raw-deploy`.
3. Im `Jenkinsfile` `NEXUS_URL` und `NEXUS_REPO` anpassen.
4. Job als *Multibranch Pipeline* oder *Pipeline from SCM* anlegen – wichtig, damit
   `GIT_PREVIOUS_SUCCESSFUL_COMMIT` gesetzt wird.

## Ablageschema in Nexus

    <NEXUS_URL>/repository/<NEXUS_REPO>/<paket>/<version>/<paket>-<version>.tar.gz

Die Version kommt aus dem jeweiligen Paket, nicht aus Git oder der Build-Nummer:
jedes der 10 Pakete wird mit seiner eigenen Version veröffentlicht.

## Woher die Version kommt

`ci/version-of.sh <paket>` liest sie **statisch**, in dieser Reihenfolge:

| Quelle | Beispiel |
|---|---|
| `setup.py`, Literal | `setup(name="alpha", version="1.2.3")` |
| `setup.py`, lokale Variable | `__version__ = "0.9.0rc1"` … `version=__version__` |
| `setup.py`, Variable aus dem Paketmodul | `from gamma import __version__` -> `gamma/__init__.py` |
| `setup.cfg` | `[metadata]` / `version = 3.4.5` |
| `setup.cfg` mit `attr:` | `version = attr: epsilon.__version__` |

Gesucht wird `__version__` in `__init__.py`, `_version.py`, `version.py` – im
Paketwurzelverzeichnis und eine Ebene tiefer.

Statisch heißt: die Datei wird geparst, nicht ausgeführt. Das ist im CI die
robustere Variante, weil `python setup.py` sonst Importe zur Build-Zeit braucht,
die zur Laufzeit gar nicht relevant sind. Wird die Version dynamisch berechnet
(z.B. aus einem Datum oder einer Git-Abfrage), scheitert das Skript mit einer
klaren Meldung – dann bewusst freischalten:

    ALLOW_SETUP_EXEC=1 ci/version-of.sh mein_paket    # ruft python setup.py --version

Suffix anhängen, falls doch mal Build-Metadaten in den Dateinamen sollen:

    VERSION_SUFFIX="+b${BUILD_NUMBER}" ci/pack.sh mein_paket

## Doppelte Versionen

Weil die Version aus `setup.py` kommt, ist „zweimal dieselbe Version hochladen"
fast immer ein vergessener Version-Bump. `ci/upload-nexus.sh` prüft deshalb vor
dem PUT per HEAD, ob die Datei schon in Nexus liegt, und bricht mit Exit-Code 2
ab. Gewollter Redeploy: Build-Parameter `ALLOW_REDEPLOY` bzw. `ALLOW_REDEPLOY=1`.

## Welche Pakete werden gebaut

`ci/changed-packages.sh` erkennt Pakete als Top-Level-Ordner mit `pyproject.toml`,
`setup.py` oder `__init__.py`. Feste Liste stattdessen:

    PACKAGES="paket1 paket2 ..." ci/changed-packages.sh <base>

Gebaut wird die Schnittmenge aus „ist ein Paket" und „liegt im `git diff` seit dem
letzten erfolgreichen Build". Zwei Sonderfälle bauen absichtlich alles:

* kein gültiger Basis-Commit (erster Build, neuer Branch, History gepruned)
* `ci/` oder `Jenkinsfile` wurden geändert

Manuell erzwingen: Build mit Parameter `BUILD_ALL`.

## Lokal testen

    ci/changed-packages.sh HEAD~1
    ci/version-of.sh mein_paket
    ci/pack.sh mein_paket                 # Version aus dem Paket
    ci/pack.sh mein_paket 0.0.1-test      # Version explizit überschreiben
    tar tzf dist/mein_paket-*.tar.gz | head

    NEXUS_URL=... NEXUS_REPO=... NEXUS_USER=... NEXUS_PASS=... \
      ci/upload-nexus.sh dist/mein_paket-1.2.3.tar.gz mein_paket 1.2.3

Alle Versionen auf einen Blick:

    for p in */; do printf '%-20s ' "${p%/}"; ci/version-of.sh "${p%/}" || true; done

## Troubleshooting: „Permission denied" beim Skriptaufruf

Das Ausführbar-Bit steckt im Git-Index, nicht in der Datei. Fehlt es (Datei per
Download hinzugefügt, Windows-Checkout, `core.fileMode=false`), scheitert der
direkte Aufruf im Workspace.

Der Jenkinsfile ruft die Skripte deshalb als `bash ci/<skript>.sh` auf – das
funktioniert unabhängig vom Dateimodus. Zusätzlich das Bit dauerhaft ins Repo
setzen:

    git update-index --chmod=+x ci/*.sh
    git commit -m "ci: Skripte ausfuehrbar machen"
    git push

Prüfen (erwartet `100755`, nicht `100644`):

    git ls-files -s ci/

Bei Windows-Clients zusätzlich sicherstellen, dass die Zeilenenden LF bleiben –
CRLF im Shebang führt zu `bad interpreter: /usr/bin/env bash^M`. In `.gitattributes`:

    ci/*.sh text eol=lf

## Umgang mit den Zugangsdaten

Drei Stellen, an denen Nexus-Credentials üblicherweise auslaufen – und wie es
hier gelöst ist:

**1. `environment { X = credentials(...) }`** bindet das Secret für die *gesamte*
Pipeline, also auch für Schritte, die es nichts angeht (Checkout, Tests, jedes
`sh`). Deshalb steht im `environment`-Block nur die Credential-*ID*; gebunden
wird per `withCredentials` direkt um den einen Upload-Schritt.

**2. Interpolation in Groovy-Strings** – `sh "... ${env.NEXUS_CRED_PSW} ..."`
schreibt das Klartext-Passwort in den Groovy-String, bevor Jenkins es maskieren
kann. Jenkins warnt darüber explizit („a secret was passed to an insecure Groovy
String"). Hier wird nichts interpoliert: `withCredentials` legt `NEXUS_USER` /
`NEXUS_PASS` in die Umgebung, das Shell-Skript liest sie selbst.

**3. `curl --user u:p`** – Argumente stehen in der Prozessliste. Jeder andere
Prozess auf dem Agent (anderer Job, anderer Container-User) sieht das Passwort
per `ps aux`. `ci/upload-nexus.sh` übergibt die Auth deshalb über
`curl --config -` via stdin: nie in argv, nie im Log. Sonderzeichen in
Passwörtern (`"`, `\`, `$`, Backticks) werden für das curl-Config-Format
escaped und nicht von der Shell interpretiert.

Zusätzlich setzt das Skript `set +x`, damit ein aufrufendes Skript mit xtrace die
Werte nicht doch noch ins Log schreibt.

Wenn ihr Secrets ganz aus der Job-Konfiguration heraushalten wollt, ist der
nächste Schritt ein Nexus-Token pro Team statt eines Deploy-Users, hinterlegt als
Jenkins-Credential mit Folder-Scope statt global.

## Hinweise

* `ci/pack.sh` erzeugt reproduzierbare Archive (`--sort=name`, feste mtime/uid/gid),
  gleicher Input => byte-identische Datei.
* Ausgeschlossen sind `__pycache__`, `*.pyc`, Test-/Lint-Caches, `.venv`, `*.egg-info`.
* `upload-nexus.sh` prüft nach dem PUT per HEAD, ob die Datei wirklich liegt – ein
  Nexus, der mit 200 antwortet aber nichts schreibt (falsche Repo-ID), fällt so auf.
* Ein fehlgeschlagenes Paket lässt die anderen parallelen Zweige weiterlaufen, der
  Build wird trotzdem rot.
* Die Build-Beschreibung in Jenkins listet am Ende `paket version` für alles,
  was in diesem Lauf veröffentlicht wurde.
