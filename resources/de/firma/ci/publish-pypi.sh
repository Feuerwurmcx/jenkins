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
#
# Vor dem Upload wird der Simple-Index (PEP 503) des Ziel-Repos gefragt, ob
# die Datei dort schon liegt. Ein Duplikat wird dann übersprungen statt
# abgelehnt: Exit 0 mit einer SKIP-Meldung, kein Fehler.
set -euo pipefail
set +x

ARCHIVE="${1:?archiv fehlt}"

: "${NEXUS_URL:?NEXUS_URL fehlt}"
: "${NEXUS_PYPI_HOSTED:?NEXUS_PYPI_HOSTED fehlt (HOSTED-Repo, nicht die Group!)}"
: "${NEXUS_USER:?NEXUS_USER fehlt}"
: "${NEXUS_PASS:?NEXUS_PASS fehlt}"

# Ein Zeilenumbruch in Nutzername/Passwort kann die curl-Config (ein Wert pro
# Zeile) nicht darstellen: curl bricht beim Parsen ab und zitiert die zweite
# Zeile woertlich im Fehlertext, der als 'cat "$ERR_FILE" >&2' ins Build-Log
# geht - Jenkins maskiert dort nur das VOLLE Secret, nicht das Fragment. Lieber
# hier klar abbrechen, bevor ueberhaupt ein curl laeuft.
case "${NEXUS_USER}${NEXUS_PASS}" in
  *$'\n'*)
    echo "FEHLER: NEXUS_USER/NEXUS_PASS enthaelt einen Zeilenumbruch - das curl-Config-Format kann den nicht darstellen" >&2
    exit 1 ;;
esac

# Leerzeichen, Tabulatoren und Zeilenumbrueche in URL oder Repo-Namen lehnt curl
# mit "URL rejected: Malformed input to a URL function" (Exit 3) ab - ohne zu
# sagen, welcher Wert schuld ist. Haeufigste Ursachen: ein CR aus einem
# CRLF-Editor am Ende der Zeile, oder ein uebersehenes Leerzeichen in der
# Jenkinsfile-Konfiguration. Beides sieht man dem Wert nicht an, deshalb hier
# vorab pruefen und die Variable benennen.
#
# Der Wert selbst wird NICHT ausgegeben: NEXUS_URL und NEXUS_PYPI_HOSTED sind
# zwar harmlos, aber die Meldung soll fuer jede Variable dieselbe Form haben,
# damit hier spaeter niemand versehentlich ein Secret ins Log schreibt.
reject_whitespace() {  # <variablenname> <wert>
  local name="$1" value="$2" i ch pos=""
  case "$value" in
    *[[:space:]]*) : ;;
    *) return 0 ;;
  esac
  for (( i=0; i<${#value}; i++ )); do
    ch="${value:i:1}"
    case "$ch" in
      [[:space:]]) pos=$((i + 1)); break ;;
    esac
  done
  echo "FEHLER: ${name} enthaelt an Position ${pos} ein Leerzeichen, einen" >&2
  echo "        Tabulator oder einen Zeilenumbruch. curl lehnt die URL sonst" >&2
  echo "        mit 'Malformed input to a URL function' ab (Exit 3)." >&2
  echo "        Haeufig ein CR aus einem CRLF-Editor oder ein Leerzeichen in" >&2
  echo "        der Jenkinsfile-Konfiguration. Sichtbar machen mit:" >&2
  echo "            printf '%s' \"\$${name}\" | od -c | head -3" >&2
  exit 1
}
reject_whitespace NEXUS_URL "$NEXUS_URL"
reject_whitespace NEXUS_PYPI_HOSTED "$NEXUS_PYPI_HOSTED"

[[ -f "$ARCHIVE" ]] || { echo "FEHLER: $ARCHIVE nicht gefunden" >&2; exit 1; }

BASE="${NEXUS_URL%/}"
UPLOAD_URL="${BASE}/service/rest/v1/components?repository=${NEXUS_PYPI_HOSTED}"

# Verzeichnis dieses Skripts - dort liegt auch sdist-meta.sh. Zur Laufzeit ist
# das .ci-lib auf dem Agent, lokal resources/de/firma/ci.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Temp-Dateien fuer Vorabpruefung und Upload. Der EXIT-trap wird hier
# registriert, VOR dem ersten 'mktemp' (das steht in already_published(),
# aufgerufen weiter unten) - sonst bliebe bei einem Signal waehrend der
# Index-Abfrage eine Temp-Datei liegen (M-6).
BODY_FILE=""
ERR_FILE=""
IDX_BODY_FILE=""
trap 'rm -f "$BODY_FILE" "$ERR_FILE" "$IDX_BODY_FILE"' EXIT

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
#
# REPO_TYPE_BESTAETIGT haelt fest, ob dieser Check wirklich "hosted pypi"
# GESEHEN hat - nicht nur, dass er ohne Exit-3-Fehler durchgelaufen ist. Die
# Vorabpruefung (already_published) braucht genau dieses staerkere Signal
# (I-A): ein "nicht pruefbar" oder ein "in der API nicht gefunden" ist hier
# bewusst kein Fehler, darf aber auch keine Abkuerzung anderswo freischalten.
REPO_TYPE_BESTAETIGT=0
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
    "hosted pypi") REPO_TYPE_BESTAETIGT=1 ;;
    "hosted "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist hosted, aber kein PyPI-Format (${type})." >&2
      exit 3 ;;
    *) echo "HINWEIS: Repo '${NEXUS_PYPI_HOSTED}' in der API nicht gefunden" >&2 ;;
  esac
}
[[ "${SKIP_REPO_CHECK:-0}" == "1" ]] || check_repo_type

# --- Liegt die Datei schon im Repo? -----------------------------------------
# PEP 503: alles klein, und -, _ und . in beliebiger Wiederholung zu einem -.
# 'Mein.Tolles_Paket' wird damit zu 'mein-tolles-paket'.
normalize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
}

# Fragt den Simple-Index (PEP 503) - dieselbe API, die auch pip liest. Gibt 0
# zurueck, wenn der Dateiname dort exakt gelistet ist.
#
# Das ist eine Abkuerzung, kein Gate: laesst sich der Index nicht abfragen
# (keine Rechte, unerwarteter Status, curl scheitert), wird nur gewarnt und
# normal hochgeladen. Ein Duplikat faengt dann der 400-Pfad ab, der ebenfalls
# ueberspringt. Eine nicht durchfuehrbare Pruefung darf den Build nicht rot
# machen - dieselbe Logik wie beim Repo-Typ-Check.
#
# I-A: diese Abkuerzung darf nur greifen, wenn check_repo_type den Typ VORHER
# bestaetigt hat (REPO_TYPE_BESTAETIGT=1, siehe dort). Grund: zeigt
# NEXUS_PYPI_HOSTED faelschlich auf ein Group-Repo, aggregiert dessen
# Simple-Index die Member - auch einen PyPI-Proxy. Ein Treffer dort sagt dann
# nichts darueber aus, ob die Datei im eigentlichen Ziel-Repo liegt; ohne die
# Bestaetigung waere das ein stiller FALSCHER Skip (rc 0, kein Upload, nichts
# publiziert). Ist der Typ nicht bestaetigt (SKIP_REPO_CHECK=1, REST-API nicht
# erreichbar, Repo nicht gefunden), wird deshalb gar nicht erst abgefragt - der
# Upload laeuft normal, ein echtes Duplikat faengt weiterhin der 400-Pfad ab.
already_published() {
  local name normalized url http body rc member links

  if [[ "${REPO_TYPE_BESTAETIGT}" != "1" ]]; then
    echo "HINWEIS: Repo-Typ nicht bestaetigt - Vorabpruefung uebersprungen (ein" >&2
    echo "         Group-Index wuerde Member aggregieren; ein Treffer dort waere" >&2
    echo "         kein verlaesslicher Beleg fuer das Ziel-Repo)" >&2
    return 1
  fi

  name="$(bash "${SCRIPT_DIR}/sdist-meta.sh" "$ARCHIVE" name)" || {
    echo "HINWEIS: Paketname nicht lesbar - Vorabpruefung uebersprungen" >&2
    return 1
  }
  normalized="$(normalize_name "$name")"
  url="${BASE}/repository/${NEXUS_PYPI_HOSTED}/simple/${normalized}/"

  IDX_BODY_FILE="$(mktemp)"
  set +e
  # --connect-timeout/--max-time (I-B): diese Abfrage ist eine Abkuerzung, die
  # scheitern darf (siehe oben) - sie darf den Build dann aber auch nicht
  # aufhalten. Kurze Werte: 10s fuer den Verbindungsaufbau, 30s insgesamt
  # reichen fuer einen Simple-Index-Abruf bei Weitem und liegen deutlich unter
  # dem, was als "haengender Build" auffiele.
  http="$(cfg_credentials \
          | curl --config - --silent --show-error \
                 --connect-timeout 10 --max-time 30 \
                 --output "$IDX_BODY_FILE" --write-out '%{http_code}' \
                 "$url" 2>/dev/null)"
  rc=$?
  set -e
  body="$(cat "$IDX_BODY_FILE")"
  rm -f "$IDX_BODY_FILE"
  IDX_BODY_FILE=""

  if [[ $rc -ne 0 ]]; then
    echo "HINWEIS: Simple-Index nicht abfragbar (curl-Exit ${rc}) - Vorabpruefung uebersprungen" >&2
    return 1
  fi
  case "$http" in
    200) : ;;
    404) return 1 ;;
    *)   echo "HINWEIS: Simple-Index lieferte HTTP ${http} - Vorabpruefung uebersprungen" >&2
         return 1 ;;
  esac

  # Link-Texte aus dem Index ziehen und EXAKT vergleichen. Ein Substring-Test
  # wuerde '<datei>' faelschlich in einem gelisteten '<datei>.asc' finden.
  #
  # Wie in sdist-meta.sh/build-sdist.sh: erst VOLLSTAENDIG in eine Variable
  # lesen, danach nur noch mit einem Herestring (<<<) filtern, statt zu pipen.
  # Unter 'set -o pipefail' wuerde 'sed ... | grep -qxF ...' mit "Write error:
  # Broken pipe" (rc 141) abbrechen, sobald grep beim ersten Treffer aussteigt
  # und die Pipe schliesst, waehrend sed (bei einem grossen Index) noch
  # weiterschreiben will - pipefail liefert dann 141 statt grep's 0, und
  # already_published meldet faelschlich "nicht gefunden" (I-1).
  member="$(basename "$ARCHIVE")"
  links="$(tr '<' '\n' <<<"$body" | sed -n 's/^[aA] [^>]*>//p')"
  grep -qxF "$member" <<<"$links"
}

if already_published; then
  echo "SKIP: $(basename "$ARCHIVE") liegt bereits in ${NEXUS_PYPI_HOSTED}"
  exit 0
fi

# --- Upload -----------------------------------------------------------------
echo "Upload -> ${UPLOAD_URL}  ($(basename "$ARCHIVE"))"

# Der EXIT-trap wurde bereits weiter oben registriert (vor dem ersten mktemp
# in already_published()) und deckt BODY_FILE/ERR_FILE mit ab (M-6).
BODY_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"

# Status per --write-out getrennt vom Body: so steht der Exit-Grund fest, statt
# aus dem Fließtext der Antwort geraten zu werden.
set +e
HTTP="$(cfg_credentials \
        | curl --config - --silent --show-error \
               --output "$BODY_FILE" --write-out '%{http_code}' \
               --request POST \
               --form "pypi.asset=@\"${ARCHIVE}\"" \
               "$UPLOAD_URL" 2>"$ERR_FILE")"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  # curls Exit-Codes nicht durchreichen: 2 und 3 sind hier als "Version
  # existiert" bzw. "falscher Repo-Typ" vergeben, und curl benutzt dieselben
  # Zahlen fuer ganz andere Fehler (3 = URL malformed, 2 = Init fehlgeschlagen).
  # Ein Aufrufer, der auf 2/3 prueft, wuerde sonst den falschen Schluss ziehen.
  # curls Zahl steht nur noch in der Meldung, nicht mehr im Exit-Code.
  echo "FEHLER: curl scheiterte (curl-Exit ${RC})" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi

BODY="$(cat "$BODY_FILE")"

case "$HTTP" in
  201|204)
    echo "OK: $(basename "$ARCHIVE")" ;;
  400)
    # Ein PyPI-hosted-Repo lehnt eine bereits vorhandene Version ab – das ist
    # fast immer ein vergessener Version-Bump, kein Infrastrukturfehler.
    # Die Vorabpruefung hat das Duplikat nicht gesehen (Index nicht abfragbar,
    # oder ein zweiter Build war schneller). Ergebnis ist dasselbe: die Datei
    # liegt im Repo, es gibt nichts zu tun.
    if grep -qiE 'already exists|does not allow updating' <<<"$BODY"; then
      echo "SKIP: $(basename "$ARCHIVE") liegt bereits in ${NEXUS_PYPI_HOSTED} (Nexus meldete HTTP 400)"
      exit 0
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
