# Repos mit nur einem Paket: Metadaten in der Repo-Wurzel

Datum: 2026-09-03. Ergaenzt `2026-09-03-pymonorepo-shared-library-design.md`.

## Problem

`changed-packages.sh` erkennt Pakete als **Top-Level-Ordner** mit
`pyproject.toml`, `setup.py` oder `setup.cfg`. Repos, die selbst ein einziges
Paket sind - Metadaten in der Repo-Wurzel, Quellcode unter `src/` -, haben
keinen solchen Ordner. Ergebnis: leere Paketliste, die Pipeline meldet "keine
Paketaenderungen", baut nichts, veroeffentlicht nichts **und ist gruen**.

Empirisch bestaetigt an zwei echten Repos:

    cd dpl-components && bash changed-packages.sh ''   ->  [] (leer)
    cd dpl-core       && bash changed-packages.sh ''   ->  [] (leer)

Beide sind ein einzelnes Distributionspaket (`[project] name = "dpl-components"`
bzw. `"dpl-core"`) im src-Layout (`[tool.setuptools.packages.find] where =
["src"]`). Die Unterordner von `src/` - z. B. `dpl_components`,
`dpl_crud_views`, `dpl_templates` - sind Import-Pakete derselben Distribution,
keine eigenen Pakete: sie haben nur `__init__.py` und keine eigenen Metadaten.
Dass sie nach der Installation einzeln in `site-packages` liegen, ist das
normale Verhalten des src-Layouts und **kein** Hinweis auf ein Monorepo.

Der naheliegende Umweg traegt nicht: `PACKAGES='.'` liefert bei leerer Basis
zwar `.`, im Jenkins-Normalfall mit echter Basis aber wieder nichts - die
Schnittmenge bildet die erste Pfadkomponente jeder geaenderten Datei
(`pyproject.toml`, `src`), und `.` ist nie darunter.

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| Erkennung | automatisch, kein neuer Konfigurationsschluessel |
| Was zaehlt als Paket-Metadaten in der Wurzel | `setup.py`, `setup.cfg`, oder `pyproject.toml` mit `[project]`- bzw. `[tool.poetry]`-Abschnitt |
| Mischform (Wurzel-Metadaten **und** Paketordner) | die Wurzel gewinnt, das Repo gilt als ein Paket |
| Stiller Leerlauf | `changed-packages.sh` weist auf stderr darauf hin, wenn es gar kein Paket findet |

Verworfen: ein `layout`-Schluessel in `pyMonorepo`. Wer ihn vergisst, bekommt
wieder den stillen Leerlauf - genau den Fehler, den diese Aenderung beseitigt.

## Erkennung

`all_packages()` bekommt einen Schritt vor der heutigen Unterordner-Suche:

1. `PACKAGES` gesetzt -> feste Liste, wie heute.
2. Sonst: hat die Repo-Wurzel Paket-Metadaten -> Ausgabe ist genau `.`, die
   Unterordner-Suche entfaellt.
3. Sonst -> Unterordner-Suche wie heute.

Paket-Metadaten in der Wurzel heisst:

* `setup.py` existiert, **oder**
* `setup.cfg` existiert, **oder**
* `pyproject.toml` existiert **und** enthaelt eine Zeile, die auf `[project]`
  oder `[tool.poetry]` passt - verankert als `^[[:space:]]*\[project\][[:space:]]*$`
  bzw. `^[[:space:]]*\[tool\.poetry\][[:space:]]*$`.

Die Verankerung ist tragend: `[project.optional-dependencies]` allein darf
nicht zaehlen, und eine `pyproject.toml`, die nur Werkzeugkonfiguration
enthaelt (`[tool.black]`, `[tool.ruff]`), darf ein echtes Monorepo nicht in ein
Einzelpaket verwandeln. `[tool.poetry]` ist mit aufgenommen, weil ein
Poetry-Projekt genauso ein Paket ist und der Fehlerfall sonst wieder der stille
Leerlauf waere.

## Aenderungserkennung

Beim Einzelpaket zaehlt **jede** geaenderte Datei als Aenderung an diesem Paket.
Die Zuordnung ueber die erste Pfadkomponente entfaellt fuer diesen Fall - genau
daran scheitert `PACKAGES='.'` heute.

Konkret: ist `.` die Paketliste und ist der `git diff` seit `<base>` nicht leer,
lautet die Ausgabe `.`; ist der Diff leer, ist die Ausgabe leer. Die
bestehenden Sonderfaelle (keine brauchbare Basis, `ci/` oder `Jenkinsfile`
geaendert) bleiben unveraendert und liefern ebenfalls `.`.

## Hinweis bei null erkannten Paketen

Findet die Auto-Erkennung weder Paketordner noch Wurzel-Metadaten, geht ein
Hinweis nach stderr:

    HINWEIS: keine Paketordner und keine Paket-Metadaten in der Repo-Wurzel
             gefunden - es wird nichts gebaut. Erwartet werden entweder
             Top-Level-Ordner mit pyproject.toml/setup.py/setup.cfg oder
             dieselben Metadaten in der Repo-Wurzel.

Der Exit-Code bleibt 0: ein Repo ohne Pakete ist kein Fehler. Der Hinweis
entfaellt, wenn `PACKAGES` gesetzt ist - dann hat der Aufrufer die Liste
bewusst vorgegeben.

Das ist der Teil, der dieses Problem sofort sichtbar gemacht haette.

## build-sdist.sh

Bleibt unveraendert bis auf die Logzeile. `build-sdist.sh .` funktioniert
bereits: die Verzeichnispruefung, die Metadatenpruefung und `cd "$PKG"`
vertragen `.`. Nur die Meldung `Ordner '.' -> <name> <version>` ist
missverstaendlich; sie bekommt fuer `.` den Text `Repo-Wurzel -> <name>
<version>`.

## vars/pyMonorepo.groovy

`build()` erzeugt je Paket eine `stage(pkg)`. Bei `.` hiesse die Stage `.` und
waere im Blue Ocean unlesbar. Sie bekommt fuer diesen Fall das Label
`Wurzelpaket`; alles andere - `withEnv(["PKG=${pkg}"])`, die Schluessel in
`versions`, die Beschreibung - bleibt unveraendert. Der Wert, der an
`build-sdist.sh` geht, bleibt `.`.

## Tests

Neues Fixture `test/fixture-single/`: ein Repo mit `pyproject.toml` in der
Wurzel (mit `[project]`) und `src/<paket>/__init__.py`. Es liegt bewusst neben
dem bestehenden `test/fixture/` statt darin - ein Monorepo-Fixture und ein
Einzelpaket-Fixture schliessen einander aus.

Faelle:

* Wurzel mit `[project]` -> Ausgabe `.`
* Wurzel mit `setup.py` (ohne pyproject.toml) -> Ausgabe `.`
* Wurzel mit `[tool.poetry]` -> Ausgabe `.`
* Wurzel-`pyproject.toml` mit **nur** `[tool.black]` in einem Monorepo -> die
  Paketordner werden gefunden, **nicht** `.`
* Wurzel-`pyproject.toml` mit **nur** `[project.optional-dependencies]` -> zaehlt
  nicht als Paket
* Mischform (Wurzel-`[project]` **und** Paketordner) -> `.`
* Einzelpaket mit echter Basis, eine Datei unter `src/` geaendert -> `.`
* Einzelpaket mit echter Basis, nichts geaendert -> leer
* Repo ohne jedes Paket -> leere Ausgabe **und** der Hinweis auf stderr
* `PACKAGES` gesetzt in einem Repo ohne Pakete -> kein Hinweis
* `build-sdist.sh .` baut (ueber den vorhandenen python3-Stub) und meldet
  `Repo-Wurzel ->` statt `Ordner '.' ->`
* Strukturtest: `vars/pyMonorepo.groovy` enthaelt das Stage-Label `Wurzelpaket`

Achtung bei den Assertions: eine leere Ausgabe beweist nichts - sie ist der
heutige Zustand. Jeder Einzelpaket-Fall muss auf die exakte Ausgabe `.` pruefen.

## Doku

* `README-ci.md`, Abschnitt "Welche Pakete werden gebaut": den Einzelpaket-Fall
  beschreiben, die Erkennungsregel nennen, die Abgrenzung zur reinen
  Werkzeugkonfiguration erklaeren und die Festlegung zur Mischform festhalten.
* Denselben Abschnitt um den Hinweis bei null Paketen ergaenzen, damit klar ist,
  wonach man im Log sucht.
* Kopfkommentar von `changed-packages.sh` entsprechend.

## Nicht verifizierbar / offen

* Ob **alle** weiteren Bitbucket-Repos dieser Bauart sind. Geprueft wurden
  `dpl-components` und `dpl-core` (beide Wurzel-`[project]`, src-Layout).
  `dpl-skill` hat gar keine `pyproject.toml` und bleibt auch nach dieser
  Aenderung kein Paket; soll es eines werden, ist das ein eigener Fall.
* Ob `build-sdist.sh .` mit echtem `python3 -m build` durchlaeuft. Lokal fehlt
  `build`; der `setup.py`-Fallback kann bei einem reinen pyproject-Projekt
  nicht greifen. Auf einem Agent mit `build` sollte es funktionieren, der erste
  echte Lauf muss es bestaetigen.

## Nachtrag 2026-09-07: zwei Entscheidungen aus der Umsetzung

Beim Abschluss-Review (I-2) fiel auf, dass die Erkennungsregel oben (Zeile 36,
54, 57-58) an genau der Stelle vom Code abweicht, die dieses Change bewusst
geaendert hat - beides inhaltlich richtig, aber nirgends festgehalten.
Nachgetragen:

**(a) `setup.cfg` allein genuegt nicht - erst ein `[metadata]`- oder
`[options]`-Abschnitt macht daraus Paket-Metadaten.** Eine Wurzel-`setup.cfg`
mit nur Linter-Konfiguration (`[flake8]`, `[mypy]`, ...) ist in
Python-Monorepos verbreitet und darf ein echtes Monorepo nicht faelschlich in
ein Einzelpaket verwandeln - dieselbe Ueberlegung, die die
`pyproject.toml`-Pruefung schon immer hatte. Ohne Inhaltspruefung waere ein
Monorepo mit so einer `setup.cfg` in der Wurzel lautlos auf ein Einzelpaket
kollabiert.

**(b) Beide Muster tolerieren inneren Leerraum und einen nachgestellten
Kommentar.** Tatsaechlich implementiert (statt der veralteten Muster in Zeile
57-58):

* `pyproject.toml`: `^[[:space:]]*\[[[:space:]]*(project|tool\.poetry)[[:space:]]*\][[:space:]]*(#.*)?$`
* `setup.cfg`: `^[[:space:]]*\[[[:space:]]*(metadata|options)[[:space:]]*\][[:space:]]*(#.*)?$`

Gueltige Syntax wie `[ project ]` oder `[metadata]  # Kommentar` - TOML und
configparser erlauben beides - fiel sonst lautlos durch, mit derselben
gefaehrlichen Richtung wie der stille Leerlauf: ein echtes Einzelpaket haette
niemand gebaut.
