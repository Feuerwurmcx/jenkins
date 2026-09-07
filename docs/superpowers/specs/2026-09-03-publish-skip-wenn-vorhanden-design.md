# publish-pypi.sh: Upload ueberspringen, wenn die Datei schon im Repo liegt

Datum: 2026-09-03. Ergaenzt `2026-09-03-publish-ohne-twine-design.md`.

## Problem

`publish-pypi.sh` laedt immer hoch und behandelt ein Duplikat als Fehler: bei
HTTP 400 mit `already exists` oder `does not allow updating` bricht es mit
Exit 2 ab ("Version im Paket erhoehen"). Fuer eine Pipeline, die dieselbe
Version erneut baut - Re-Run eines Builds, unveraendertes Paket in einem
Monorepo-Build ueber mehrere Pakete - ist das ein roter Build ohne Ursache im
Code.

Gewuenscht: vor dem Upload pruefen, ob die Datei schon da ist, und den Upload
dann ueberspringen.

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| Pruefmechanismus | Simple-Index (`/repository/<repo>/simple/<name>/`), die Standard-API nach PEP 503 |
| Verhalten bei Treffer | `SKIP`-Meldung, **Exit 0**, kein Upload |
| 400 "already exists" trotz Vorabpruefung | ebenfalls Exit 0 (ueberspringen), nicht mehr Exit 2 |
| Exit 2 | entfaellt aus dem Vertrag - nichts produziert ihn mehr |

Verworfen: die Nexus-Search-API (`/service/rest/v1/search/assets`) - Nexus-
spezifisch statt Standard, keyword-basiert, exakter Vergleich muesste ohnehin
selbst passieren. Ebenfalls verworfen: `HEAD` auf den konstruierten Ablagepfad
`/repository/<repo>/packages/<name>/<version>/<datei>` - diesen Pfad vergibt
Nexus, wir wuerden ihn raten.

**Bewusste Folge:** ein vergessener Version-Bump ist ab jetzt lautlos. Der Build
wird gruen, im Repo bleibt die alte Version. Das ist der Preis der Idempotenz
und gehoert ausdruecklich ins README.

## Die Pruefung

Neue Funktion `already_published()`, laeuft nach der Repo-Typ-Pruefung und vor
dem Upload.

1. **Paketnamen aus der PKG-INFO** - per Aufruf von `sdist-meta.sh` aus dem
   eigenen Verzeichnis (`$(dirname "${BASH_SOURCE[0]}")`; zur Laufzeit
   `.ci-lib`, lokal `resources/de/firma/ci`). Nicht aus dem Dateinamen
   zerlegen: der Kopfkommentar von `sdist-meta.sh` begruendet, warum das
   mehrdeutig ist (Paketnamen duerfen selbst Bindestriche enthalten).
2. **PEP-503-Normalisierung** fuer die URL: alles klein, und `-`, `_`, `.` in
   beliebiger Wiederholung zu einem einzelnen `-`. `Mein.Tolles_Paket` wird zu
   `mein-tolles-paket`.
3. `GET {BASE}/repository/{NEXUS_PYPI_HOSTED}/simple/{normalisierter-name}/`,
   Zugangsdaten wie ueberall per `curl --config -` von stdin.
4. Aus der Antwort die Link-Texte extrahieren und **exakt** gegen
   `basename "$ARCHIVE"` vergleichen - kein Substring-Vergleich. Sonst wuerde
   `foo-1.0.tar.gz` faelschlich in einem gelisteten `foo-1.0.tar.gz.asc`
   gefunden.

| Antwort | Verhalten |
|---|---|
| 200, Dateiname exakt in der Liste | `SKIP: <datei> liegt bereits in <repo>`, Exit 0, kein Upload |
| 200, Dateiname nicht in der Liste | Upload laeuft |
| 404 (Paket im Repo unbekannt) | Upload laeuft |
| 401, 403, 5xx oder curl-Exit != 0 | Hinweis auf stderr, Upload laeuft trotzdem |

Der letzte Fall ist tragend: eine nicht durchfuehrbare Pruefung darf den Build
nicht rot machen. Sie ist eine Abkuerzung, kein Gate - dieselbe Logik wie beim
Repo-Typ-Check, der bei fehlenden Rechten ebenfalls nur warnt.

Abschalten laesst sich die Pruefung nicht ueber einen eigenen Schalter; wer sie
nicht will, bekommt durch den 400-Pfad dasselbe Ergebnis, nur eine HTTP-Runde
spaeter.

## Statuszuordnung nach der Aenderung

| Fall | Exit |
|---|---|
| Upload erfolgreich (201/204) | 0 |
| Datei laut Simple-Index schon da | 0, mit `SKIP:` |
| 400 mit `already exists` / `does not allow updating` | 0, mit `SKIP:` |
| 400 sonst | 1, Status und Body |
| 401/403 | 1, Zugangsdaten/Rechte |
| 404 beim Upload | 1, Repository existiert nicht |
| anderer Status | 1, Status und Body |
| curl scheitert | 1, curl-Exit in der Meldung |
| falscher Repo-Typ (group/proxy/hosted-nicht-pypi) | 3 |
| fehlende Pflichtvariable, Whitespace in URL/Repo, Archiv fehlt | 1 |

Exit 2 kommt nicht mehr vor.

## Tests

Der `curl`-Stub unterscheidet heute zwei Aufrufarten anhand der Anwesenheit von
`--output` (Repo-Typ-Check ohne, Upload mit). Mit der Simple-Index-Abfrage
kommt eine dritte dazu; der Stub muss kuenftig an der URL unterscheiden und je
Aufrufart einen eigenen Status und Body liefern koennen.

Neue Faelle:

* Index 200, Dateiname in der Liste -> Exit 0, Meldung enthaelt `SKIP:`, **und
  der Upload-Aufruf findet nachweislich nicht statt** (Zaehlung der
  curl-Aufrufe, wie beim bestehenden `SKIP_REPO_CHECK`-Test)
* Index 200, Dateiname nicht in der Liste -> Upload laeuft, Exit 0 mit `OK:`
* Index listet `<datei>.asc`, gesucht wird `<datei>` -> **kein** Skip, Upload laeuft
* Index 404 -> Upload laeuft
* Index 401 -> Hinweis auf stderr, Upload laeuft trotzdem, Exit 0
* curl scheitert bei der Index-Abfrage -> Hinweis, Upload laeuft trotzdem
* Upload liefert 400 `already exists` -> Exit 0 mit `SKIP:` (nicht mehr Exit 2)
* die abgefragte Index-URL enthaelt den normalisierten Namen: bei
  `Mein.Tolles_Paket` muss `simple/mein-tolles-paket/` aufgerufen werden

Achtung bei den Assertions: `rc 0` allein beweist nichts, denn der erfolgreiche
Upload liefert ebenfalls 0. Was den Skip belegt, ist die `SKIP:`-Meldung
zusammen mit der Zaehlung, dass kein Upload-Aufruf stattfand.

## Doku

* Kopfkommentar von `publish-pypi.sh`: die Vorabpruefung und ihre Grenzen.
* `README-ci.md`, Abschnitt "Doppelte Versionen": vollstaendig neu - Duplikate
  werden uebersprungen, Exit 2 gibt es nicht mehr, und der Hinweis, dass ein
  vergessener Version-Bump dadurch nicht mehr auffaellt.
* `README-ci.md`: Exit-Code-Liste ohne 2.
* `2026-09-03-publish-ohne-twine-design.md`: Nachtrag, dass die dort
  festgelegte Exit-2-Regel durch diese Spec ersetzt ist.

## Nicht verifizierbar

Dass Nexus den Simple-Index unter `/repository/<repo>/simple/<name>/` ausliefert
und die Dateinamen als Link-Text fuehrt, ist PEP 503, aber hier ohne erreichbares
Nexus nicht pruefbar. Weicht Nexus davon ab, greift die Vorabpruefung nicht, der
Upload laeuft, und der 400-Pfad ueberspringt das Duplikat trotzdem - der
Fehlerfall ist "Pruefung nuetzt nichts", nicht "Build kaputt". Der erste echte
Lauf sollte das Log auf die `SKIP:`-Zeile pruefen, wenn dieselbe Version zweimal
gebaut wird.
