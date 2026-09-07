#!/usr/bin/env bash
# Listet die Pakete, die sich seit <base> geaendert haben - eines pro Zeile.
#
#   changed-packages.sh <base>
#
# Ein Paket ist ein Top-Level-Ordner mit pyproject.toml, setup.py oder
# setup.cfg - genau das, was build-sdist.sh auch bauen kann (kein
# __init__.py: das war ein Erbe der alten RAW/tar.gz-Generation, siehe
# Nachtrag in docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md).
#
# Statt der Auto-Erkennung eine feste Liste:
#
#   PACKAGES="paket1 paket2" changed-packages.sh <base>
#
# Ist das Repo SELBST ein Paket (Metadaten in der Repo-Wurzel, Quellcode unter
# src/, keine Paketordner), gibt es keine Auto-Erkennung dafuer - das Repo muss
# es sagen:
#
#   ROOT_PACKAGE=true changed-packages.sh <base>
#
# Dann ist die Paketliste genau "." und jede geaenderte Datei zaehlt dafuer.
# Bewusst ein Schalter und keine Erkennung: ob eine Wurzel-pyproject.toml ein
# Distributionspaket beschreibt oder nur Werkzeugkonfiguration
# ([tool.black], [flake8], ...) eines Monorepos ist, laesst sich ohne echten
# TOML-Parser nicht zuverlaessig entscheiden. Beide Fehlrichtungen sind teuer:
# ein Monorepo, das faelschlich als EIN Paket gilt, verliert alle seine Pakete;
# ein Einzelpaket, das nicht erkannt wird, baut gar nichts. Wer sein Repo
# kennt, weiss die Antwort - das Skript nicht.
#
# Ausgegeben wird die Schnittmenge aus "ist ein Paket" und "steckt im git diff
# seit <base>". Drei Faelle bauen bewusst alles: keine brauchbare Basis (erster
# Build, neuer Branch, gepruntete History) sowie Aenderungen an ci/ oder am
# Jenkinsfile - wer die CI aendert, will sie auf allem sehen.
#
# Nutzdaten gehen nach stdout, Hinweise nach stderr: der Aufrufer liest stdout
# als Paketliste.
set -euo pipefail
shopt -s nullglob

BASE="${1:-}"

# ROOT_PACKAGE auswerten, BEVOR irgendetwas ausgegeben wird.
#
# Ein unverstandener Wert bricht ab, statt still als "aus" zu gelten: ein
# Tippfehler (ROOT_PACKAGE=ture) wuerde sonst dazu fuehren, dass ein
# Einzelpaket-Repo keine Pakete findet, nichts baut - und gruen bleibt. Genau
# dieser stille Leerlauf ist der Fehler, gegen den dieser Schalter existiert.
# 'false' ist ausdruecklich erlaubt: Groovy reicht Boolean-Parameter als
# String durch, ROOT_PACKAGE=false ist der Normalfall.
ROOT_PACKAGE_ON=0
case "$(printf '%s' "${ROOT_PACKAGE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
  ''|false|0|no|off|nein) ROOT_PACKAGE_ON=0 ;;
  true|1|yes|on|ja)       ROOT_PACKAGE_ON=1 ;;
  *)
    echo "FEHLER: ROOT_PACKAGE='${ROOT_PACKAGE}' ist weder wahr noch falsch." >&2
    echo "        Erlaubt: true/1/yes/on/ja bzw. false/0/no/off/nein (leer = aus)." >&2
    exit 2
    ;;
esac

# ROOT_PACKAGE und eine abweichende PACKAGES-Liste widersprechen sich: das Repo
# ist entweder EIN Paket oder eine Menge von Paketordnern, nicht beides. Still
# eines von beiden zu bevorzugen hiesse, die Haelfte der erwarteten Pakete
# ohne Meldung zu verlieren. PACKAGES='.' sagt dasselbe wie ROOT_PACKAGE und
# ist deshalb vertraeglich.
if [[ $ROOT_PACKAGE_ON -eq 1 && -n "${PACKAGES:-}" ]]; then
  # read -ra: Wortaufteilung ohne Pfadnamen-Expansion, siehe all_packages().
  # -d '': ohne das liest read nur bis zum ersten Zeilenumbruch - eine
  # mehrzeilige Liste haette hier still nur ihre erste Zeile geprueft.
  read -ra _rp_pkgs -d '' <<<"${PACKAGES}" || true
  # Laenge 0 (PACKAGES bestand nur aus Leerraum) ist kein Widerspruch: eine
  # leere Liste bedeutet ohnehin "keine feste Liste", siehe all_packages().
  if [[ ${#_rp_pkgs[@]} -gt 0 ]] && { [[ ${#_rp_pkgs[@]} -ne 1 ]] || [[ "${_rp_pkgs[0]}" != "." ]]; }; then
    echo "FEHLER: ROOT_PACKAGE=true und PACKAGES='${PACKAGES}' widersprechen sich." >&2
    echo "        ROOT_PACKAGE macht das ganze Repo zu EINEM Paket '.'; eine" >&2
    echo "        Liste von Paketordnern passt dazu nicht. Eines von beidem" >&2
    echo "        setzen (PACKAGES='.' waere gleichbedeutend mit ROOT_PACKAGE)." >&2
    exit 2
  fi
fi

all_packages() {
  if [[ $ROOT_PACKAGE_ON -eq 1 ]]; then
    # Auf stderr, nicht stdout: stdout ist die Paketliste, die der Aufrufer per
    # 'sh(returnStdout: true)' liest. Ohne die Zeile waere im Log nur "Pakete
    # : ." zu sehen, nie der Grund dafuer.
    echo "HINWEIS: ROOT_PACKAGE gesetzt - das Repo gilt als EIN Paket '.'" >&2
    printf '%s\n' '.'
    return
  fi
  # PACKAGES gesetzt, aber leer (PACKAGES=""): faellt bewusst auf die
  # Auto-Erkennung unten zurueck, nicht auf eine leere Liste. Das ist keine
  # Anforderung der Spec, aber vertretbar - hier festgehalten, damit es
  # niemanden ueberrascht.
  if [[ -n "${PACKAGES:-}" ]]; then
    # read -ra statt unquotierter Expansion ("printf '%s\n' ${PACKAGES}"):
    # PACKAGES ist eine FESTE Liste, kein Glob-Muster. Mit der unquotierten
    # Variante griff das globale 'shopt -s nullglob' (siehe oben) auch hier
    # zu: PACKAGES='nomatch[x]' verschwand spurlos, PACKAGES='al*' wurde zu
    # 'alpha' expandiert. read -ra fuehrt nur Wortaufteilung durch, keine
    # Pfadnamen-Expansion.
    local -a pkgs
    # -d '': ohne das endet read am ersten Zeilenumbruch, und alles ab der
    # zweiten Zeile verschwindet spurlos - bei einer Paketliste heisst das:
    # Pakete werden nicht gebaut, ohne jede Meldung. read gibt am Dateiende
    # ohne Trenner nichtnull zurueck, deshalb '|| true' unter 'set -e'.
    read -ra pkgs -d '' <<<"${PACKAGES}" || true
    # Bash 3.2: "${pkgs[@]}" bricht unter 'set -u' mit "unbound variable" ab,
    # wenn das Array leer ist (z. B. PACKAGES bestand nur aus Leerzeichen).
    # Deshalb erst die Laenge pruefen, bevor das Array expandiert wird.
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      printf '%s\n' "${pkgs[@]}" | sort -u
    fi
    return
  fi
  local d found
  found="$(
    for d in */; do
      d="${d%/}"
      if [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/setup.cfg" ]]; then
        printf '%s\n' "$d"
      fi
    done | sort -u
  )"
  if [[ -z "$found" ]]; then
    # Der stille Leerlauf war der eigentliche Fehler: ein Repo, das nichts
    # baut, war bisher nicht von einem Repo ohne Aenderungen zu unterscheiden.
    # Der Hinweis nennt ROOT_PACKAGE, weil ein Repo, das selbst ein Paket ist,
    # genau hier landet - ohne den Schalter sieht das Skript keine Pakete.
    # Exit-Code bleibt 0 - ein Repo ohne Pakete ist kein Fehler.
    echo "HINWEIS: keine Paketordner gefunden - es wird nichts gebaut." >&2
    echo "         Erwartet werden Top-Level-Ordner mit pyproject.toml," >&2
    echo "         setup.py oder setup.cfg. Ist dieses Repo selbst EIN Paket" >&2
    echo "         (Metadaten in der Wurzel, Quellcode unter src/), dann" >&2
    echo "         rootPackage: true setzen bzw. den Parameter ROOT_PACKAGE." >&2
    return
  fi
  printf '%s\n' "$found"
}

usable_base() {
  [[ -n "$BASE" ]] || return 1
  git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1
}

if ! usable_base; then
  echo "HINWEIS: keine brauchbare Basis ('${BASE}') - baue alle Pakete" >&2
  all_packages
  exit 0
fi

# core.quotepath=false: git quotet Pfade mit Nicht-ASCII-Zeichen sonst als
# Oktal-Escape in Anfuehrungszeichen (z. B. "alpha/\303\274bersetzung.txt").
# "cut -d/ -f1" macht daraus '"alpha' statt 'alpha' - passt gegen keinen
# Paketnamen, das Paket verschwindet lautlos. In einem deutschsprachigen
# Repo (Umlaute in Dateinamen) ist das kein Randfall.
# --no-renames: ohne dieses Flag meldet git bei "git mv alpha/x.py
# beta/x.py" wegen der Rename-Erkennung nur den neuen Pfad - alpha verliert
# eine Datei, wird aber nicht als geaendert erkannt. Mit --no-renames
# erscheinen alter und neuer Pfad als je eigene Zeile.
CHANGED_FILES="$(git -c core.quotepath=false diff --no-renames --name-only "$BASE" HEAD)"

if grep -qE '^(ci/|Jenkinsfile$)' <<<"$CHANGED_FILES"; then
  echo "HINWEIS: CI-Konfiguration geaendert - baue alle Pakete" >&2
  all_packages
  exit 0
fi

# Erste Pfadkomponente je geaenderter Datei = moeglicher Paketordner.
TOUCHED="$(cut -d/ -f1 <<<"$CHANGED_FILES" | sort -u)"

while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  # '.' ist das Repo selbst - es taucht in TOUCHED nie auf, denn die Zuordnung
  # ueber die erste Pfadkomponente gibt es dort nicht: das Paket IST das Repo.
  # Deshalb zaehlt jede geaenderte Datei dafuer. Gilt fuer ROOT_PACKAGE ebenso
  # wie fuer ein ausdrueckliches PACKAGES='.'.
  if [[ "$pkg" == "." ]]; then
    [[ -n "$CHANGED_FILES" ]] && printf '%s\n' '.'
    continue
  fi
  if grep -qxF "$pkg" <<<"$TOUCHED"; then
    printf '%s\n' "$pkg"
  fi
done < <(all_packages)

exit 0
