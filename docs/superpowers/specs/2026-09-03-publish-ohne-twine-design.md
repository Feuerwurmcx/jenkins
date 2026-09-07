# publish-pypi.sh ohne twine: Upload ueber die Nexus-Components-API

Datum: 2026-09-03. Ergaenzt `2026-09-03-pymonorepo-shared-library-design.md`.

## Problem

Auf dem Jenkins-Agent ist `twine` nicht verfuegbar, und Nachinstallieren ist
ausgeschlossen. `publish-pypi.sh` laedt heute per `python3 -m twine upload` hoch
(Zeile 72) und ist damit als einziges der vier Skripte nicht lauffaehig.

Bestaetigt: `python3 -m build` bzw. `setuptools` ist vorhanden — `build-sdist.sh`
bleibt unveraendert. `curl` und `python3` sind vorhanden und werden in
`publish-pypi.sh` bereits benutzt (Repo-Typ-Check, JSON-Parsing).

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| Upload-Weg | `curl` POST auf die Nexus-REST-Components-API |
| Zugangsdaten | weiterhin `curl --config -` ueber stdin, nie ueber argv |
| Umfang | nur der Upload-Schritt in `publish-pypi.sh`; Bauen, Metadaten, Groovy unveraendert |

Verworfen: der Legacy-Weg (`:action=file_upload` gegen `/repository/<repo>/`,
das was twine intern tut) — er verlangt Name, Version, filetype, pyversion und
metadata_version als eigene Formularfelder, die erst aus der PKG-INFO gelesen
werden muessten. Die Components-API braucht nur die Datei. Ebenfalls verworfen:
ein eigenes `urllib`-Multipart-Skript — mehr eigener Code ohne Gewinn, und die
Zugangsdaten muessten durch einen weiteren Prozess.

## Upload

```
POST {NEXUS_URL}/service/rest/v1/components?repository={NEXUS_PYPI_HOSTED}
     -F pypi.asset=@{archiv}
```

Aufrufform:

```bash
HTTP="$(cfg_credentials | curl --config - --silent --show-error \
          --output "$BODY_FILE" --write-out '%{http_code}' \
          --request POST --form "pypi.asset=@\"${ARCHIVE}\"" \
          "$UPLOAD_URL" 2>"$ERR_FILE")"
```

Der HTTP-Status kommt getrennt vom Body (`--write-out` auf stdout, Body in eine
Temp-Datei). Das ist der Kern der Aenderung: bisher musste der Exit-Grund aus
dem Fliesstext von twine geraten werden.

| Fall | Verhalten |
|---|---|
| curl selbst scheitert (rc != 0: Netz, TLS, DNS) | Exit 1 (siehe Nachtrag unten), Inhalt von `$ERR_FILE` nach stderr |
| 201 oder 204 | `OK: <basename>`, Exit 0 |
| 400 **und** Body enthaelt `already exists` oder `does not allow updating` (case-insensitive) | Exit 2, "Version liegt bereits im Repo. Version im Paket erhoehen." (siehe Nachtrag unten: seit der Vorabpruefung Exit 0 mit `SKIP`) |
| 400 sonst | Exit 1, Status und Body ausgeben |
| 401 oder 403 | Exit 1, "Zugangsdaten abgelehnt oder keine Deploy-Rechte auf '<repo>'" |
| 404 | Exit 1, "Repository '<repo>' existiert nicht unter <NEXUS_URL>" |
| alles andere | Exit 1, Status und Body ausgeben |

Exit-Codes zum Zeitpunkt dieser Spec: 2 = Version existiert, 3 = falscher
Repo-Typ, 1 = sonstiger Fehler. Exit 2 ist seither entfallen, siehe Nachtrag
unten.

Nexus antwortet auf einen erfolgreichen Component-Upload mit 204 (kein Body);
201 wird mit akzeptiert, weil aeltere 3.x-Staende das liefern.

Der Repo-Typ-Check (`check_repo_type`, Exit 3 bei group/proxy/hosted-nicht-pypi,
`SKIP_REPO_CHECK=1` zum Abschalten) bleibt unveraendert.

## Zugangsdaten

Beide curl-Aufrufe holen die Credentials aus derselben Funktion:

```bash
# curl liest die Zugangsdaten von stdin statt aus argv - sonst stuenden sie in
# der Prozessliste jedes Nutzers auf dem Agent.
cfg_credentials() {
  printf 'user = "%s:%s"\n' "$(cfg_escape "$NEXUS_USER")" "$(cfg_escape "$NEXUS_PASS")"
}

# Im curl-Config-Format sind " und \ Sonderzeichen. Ohne Escaping bricht ein
# Passwort mit Anfuehrungszeichen den Aufruf - beim Repo-Check still (er
# degradiert zur Warnung), beim Upload laut.
cfg_escape() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }
```

Damit faellt ein zurueckgestellter Befund aus dem Abschluss-Review des ersten
Umbaus weg (fehlendes Escaping; das geloeschte `upload-nexus.sh` hatte es).

Ein zweiter faellt ersatzlos: die bisherige Erkennung doppelter Versionen per
`grep -qiE '400|already exists|...'` ueber die twine-Ausgabe matchte "400" auch
in einem Dateinamen wie `foo-1.400.tar.gz`. Mit dem HTTP-Status als eigenem
Wert entfaellt das Raten.

## Tests

Heute steht der Upload als `SKIP  publish-pypi.sh echter Upload`. Mit einem
`curl`-Stub im PATH — dasselbe Muster, das `test/run-tests.sh` bereits fuer
`python3` verwendet — wird alles ausser dem echten Netzwerkaufruf pruefbar. Der
Stub schreibt seine Argumente und sein stdin in Dateien und gibt einen per
Umgebungsvariable steuerbaren HTTP-Status aus.

Neue Faelle:

* 204 -> Exit 0, Ausgabe enthaelt `OK:`
* 400 mit Body `... already exists ...` -> Exit 2, Meldung nennt den Version-Bump
  (Stand dieser Spec; seit dem Nachtrag unten ersetzt durch Exit 0 mit `SKIP`)
* 400 mit anderem Body -> Exit 1, Status und Body erscheinen in der Ausgabe
* 401 -> Exit 1, Meldung nennt Zugangsdaten/Rechte
* 404 -> Exit 1, Meldung nennt das Repository
* die aufgerufene URL ist `<base>/service/rest/v1/components?repository=<repo>`
* das Formularfeld heisst `pypi.asset` und zeigt auf das uebergebene Archiv
* **das Passwort steht nicht in argv** (Stub-Argumente werden danach durchsucht)
* ein Passwort mit `"` und `\` kommt escaped in der curl-Config an
* `SKIP_REPO_CHECK=1` ueberspringt den Repo-Typ-Check: genau ein curl-Aufruf
  (gezaehlt an den Vorkommen von `--config` in `curl-args`, das jeder
  Aufruf genau einmal traegt); ohne die Variable laufen Repo-Typ-Check und
  Upload, also zwei

Der Stub liegt wie der python3-Stub nur fuer den jeweiligen Aufruf vorn im PATH,
nicht global. Die bestehenden Guard-Clause-Tests (fehlendes Argument, fehlende
Umgebungsvariablen) bleiben unveraendert.

Ungetestet bleibt weiterhin der echte Netzwerkaufruf gegen ein Nexus; das ist
ehrlich als SKIP auszuweisen.

## Doku

* Kopfkommentar von `publish-pypi.sh`: twine raus, Components-API rein.
* `README-ci.md`, "Voraussetzungen auf dem Agent": `twine` streichen; `curl`
  steht dort schon.
* `README-ci.md`, "Umgang mit den Zugangsdaten": Punkt 3 nennt heute
  `TWINE_USERNAME`/`TWINE_PASSWORD`. Neu: beide curl-Aufrufe lesen die
  Zugangsdaten ueber `--config -` von stdin, inklusive Escaping.
* `README-ci.md`, Abschnitt zu doppelten Versionen: Exit 2 kommt jetzt aus
  HTTP 400 plus Body, nicht mehr aus der twine-Ausgabe. (Stand dieser Spec;
  seit dem Nachtrag unten beschreibt der Abschnitt die Vorabpruefung mit
  Exit 0/`SKIP` statt Exit 2.)
* Kein Zusammenhang mit `vars/pyMonorepo.groovy` — dort aendert sich nichts.

## Nicht verifizierbar

Dass Nexus auf den Component-Upload wirklich 204 liefert und bei doppelter
Version 400 mit einem der beiden Textbausteine, ist der Sonatype-Dokumentation
entnommen und hier nicht ausfuehrbar. Der erste echte Lauf gegen ein Test-Repo
muss das bestaetigen; der "sonst"-Zweig gibt Status und Body aus, damit ein
abweichender Status sofort sichtbar ist statt stillschweigend als Erfolg oder
als falscher Exit-Code durchzugehen.

## Nachtrag 2026-09-03: vier Entscheidungen aus der Umsetzung

Beim Abschluss-Review (I-2) fiel auf, dass vier Entscheidungen, die waehrend
der Umsetzung getroffen wurden, in dieser Spec nicht vorkamen - obwohl der
Plan sie als verbindliche Quelle nennt. Nachgetragen:

**(a) Zeilenumbruch-Guard vor jedem curl-Aufruf.** Ein Zeilenumbruch in
`NEXUS_USER`/`NEXUS_PASS` kann die curl-Config (ein Wert pro Zeile) nicht
darstellen: curl bricht beim Parsen ab und zitiert die zweite Zeile woertlich
im Fehlertext, der per `cat "$ERR_FILE" >&2` ins Build-Log geht - Jenkins
maskiert dort nur das VOLLE Secret, nicht ein Fragment davon. `publish-pypi.sh`
lehnt einen solchen Wert deshalb vorab mit Exit 1 und eigener Meldung ab,
bevor ueberhaupt ein curl-Aufruf stattfindet. Empirisch belegt: curl ohne
diesen Guard, gefuettert mit einer zweizeiligen Config, zitiert das Fragment
woertlich auf stderr ("`'geheimB"' is unknown`").

**(b) `--form` mit Anfuehrungszeichen um den Pfad.** `--form
"pypi.asset=@\"${ARCHIVE}\""` statt der oben (Abschnitt "Upload") urspruenglich
gezeigten Form ohne Quotes. Ohne die Quotes deutet curl `;` und `,` im Wert als
Trennzeichen - ein Archivpfad mit `,` scheiterte gemessen mit
"`curl: (26) Failed to open/read local data`" statt hochzuladen.

**(c) `check_repo_type` wird ueber `STUB_REPOS_JSON` getestet.** Vier Faelle:
group, proxy, hosted mit falschem Format (kein `pypi`), hosted/pypi (laesst
den Upload tatsaechlich laufen). Der Testtreiber steuert das Antwort-JSON des
Repo-Typ-Check-Aufrufs ueber die Umgebungsvariable `STUB_REPOS_JSON` des
curl-Stubs.

**(d) `trap 'rm -f "$BODY_FILE" "${ERR_FILE:-}"' EXIT` steht direkt nach dem
ersten `mktemp`.** So raeumt der Trap auch dann auf, wenn zwischen den beiden
`mktemp`-Aufrufen (oder danach) etwas fehlschlaegt - nicht erst, nachdem beide
Temp-Dateien existieren.

Ausserdem, im Zusammenhang mit (a): curl-Fehler enden mit Exit 1, nicht mit
curls rohem Exit-Code (Abschluss-Review I-1). curl benutzt 2 und 3 fuer eigene
Fehler (z. B. 3 = URL malformed), und genau diese Zahlen sind hier bereits als
"Version existiert" bzw. "falscher Repo-Typ" vergeben - ein Aufrufer, der auf
2/3 prueft, wuerde sonst bei einem curl-Fehler den falschen Schluss ziehen.
curls Exit-Code steht seither nur noch in der Fehlermeldung
("`FEHLER: curl scheiterte (curl-Exit <n>)`"), nicht mehr im Exit-Code des
Skripts. Die Tabelle im Abschnitt "Upload" und Zeile 42 dieser Spec sind
entsprechend korrigiert.

## Nachtrag 2026-09-03: Duplikate werden uebersprungen, Exit 2 entfaellt

Die Statuszuordnung oben nennt fuer HTTP 400 mit `already exists` bzw.
`does not allow updating` den Exit-Code 2. Das ist ersetzt: seit der
Vorabpruefung ueber den Simple-Index gilt ein Duplikat als "nichts zu tun" und
endet mit Exit 0 und einer `SKIP`-Meldung - sowohl wenn die Vorabpruefung es
findet als auch wenn erst Nexus mit 400 antwortet. Exit-Code 2 kommt im Skript
nicht mehr vor. Details: `2026-09-03-publish-skip-wenn-vorhanden-design.md`.
