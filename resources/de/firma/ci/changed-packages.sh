#!/usr/bin/env bash
# Listet die Pakete, die sich seit <base> geaendert haben - eines pro Zeile.
#
#   changed-packages.sh <base>
#
# Ein Paket ist ein Top-Level-Ordner mit pyproject.toml, setup.py oder
# setup.cfg - genau das, was build-sdist.sh auch bauen kann (kein
# __init__.py: das war ein Erbe der alten RAW/tar.gz-Generation, siehe
# Nachtrag in docs/superpowers/specs/2026-09-03-pymonorepo-shared-library-design.md).
# Hat die Repo-Wurzel selbst solche Metadaten, gilt das ganze Repo als EIN
# Paket namens ".", und die Suche nach Unterordnern entfaellt.
# Statt der Auto-Erkennung eine feste Liste:
#
#   PACKAGES="paket1 paket2" changed-packages.sh <base>
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

# Hat die Repo-Wurzel selbst Paket-Metadaten? Dann ist das Repo EIN Paket und
# kein Monorepo mit Paketordnern - so gebaut sind z. B. Repos mit src-Layout,
# bei denen die Unterordner von src/ Import-Pakete derselben Distribution sind
# und keine eigenen Metadaten haben.
#
# Bei pyproject.toml genuegt die blosse Datei nicht: sie enthaelt oft nur
# Werkzeugkonfiguration ([tool.black], [tool.ruff]) und steht dann auch in
# einem echten Monorepo in der Wurzel. Erst ein [project]- oder
# [tool.poetry]-Abschnitt macht daraus ein Distributionspaket. Das Muster ist
# verankert (^...$), erlaubt aber Leerraum um den Abschnittsnamen und einen
# Kommentar dahinter, damit gueltiges TOML wie "[project]  # Kommentar" oder
# "[ project ]" erkannt wird - waehrend "[project.optional-dependencies]"
# weiterhin NICHT zaehlt (dort folgt auf "project" kein "]", sondern ".").
# Bekannte Grenze, bewusst nicht behoben: ein "[project]" als Text innerhalb
# eines mehrzeiligen TOML-Strings wuerde faelschlich mitgezaehlt - sauber nur
# mit einem echten TOML-Parser loesbar.
#
# Bei setup.cfg gilt dieselbe Ueberlegung wie bei pyproject.toml: eine
# Wurzel-setup.cfg mit nur Linter-Konfiguration ([flake8], [mypy], ...) ist in
# Python-Monorepos verbreitet und darf ein Monorepo nicht faelschlich zum
# Einzelpaket machen. Erst ein [metadata]- oder [options]-Abschnitt macht
# daraus Paket-Metadaten. Das Muster ist verankert (^...$) und toleriert
# denselben Leerraum und Kommentar wie bei pyproject.toml: configparser (der
# setup.cfg parst) erlaubt wie TOML Leerraum um den Abschnittsnamen und einen
# Kommentar dahinter, "[ metadata ]" und "[metadata]  # Kommentar" sind darin
# ebenso gueltig wie "[metadata]". Eine strengere Pruefung wuerde ein echtes
# Einzelpaket mit so formatierter setup.cfg lautlos auf "kein Paket" fallen
# lassen - dieselbe gefaehrliche Richtung, gegen die auch die
# pyproject-Toleranz eingefuehrt wurde. "[options.extras_require]" und
# "[metadata.foo]" zaehlen weiterhin NICHT: dort folgt auf den Abschnittsnamen
# kein "]", sondern ein ".".
# setup.py bleibt dagegen bewusst OHNE Inhaltspruefung: anders als setup.cfg
# oder pyproject.toml hat eine setup.py in der Wurzel praktisch keinen
# verbreiteten Nur-Werkzeugkonfiguration-Zweck - sie existiert so gut wie
# immer, um ein Paket zu bauen.
root_is_package() {
  [[ -f setup.py ]] && return 0
  if [[ -f setup.cfg ]] && grep -qE '^[[:space:]]*\[[[:space:]]*(metadata|options)[[:space:]]*\][[:space:]]*(#.*)?$' setup.cfg; then
    return 0
  fi
  [[ -f pyproject.toml ]] || return 1
  grep -qE '^[[:space:]]*\[[[:space:]]*(project|tool\.poetry)[[:space:]]*\][[:space:]]*(#.*)?$' pyproject.toml
}

all_packages() {
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
    read -ra pkgs <<<"${PACKAGES}"
    # Bash 3.2: "${pkgs[@]}" bricht unter 'set -u' mit "unbound variable" ab,
    # wenn das Array leer ist (z. B. PACKAGES bestand nur aus Leerzeichen).
    # Deshalb erst die Laenge pruefen, bevor das Array expandiert wird.
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      printf '%s\n' "${pkgs[@]}" | sort -u
    fi
    return
  fi
  if root_is_package; then
    printf '%s\n' '.'
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
    # Exit-Code bleibt 0 - ein Repo ohne Pakete ist kein Fehler.
    echo "HINWEIS: keine Paketordner und keine Paket-Metadaten in der" >&2
    echo "         Repo-Wurzel gefunden - es wird nichts gebaut. Erwartet" >&2
    echo "         werden entweder Top-Level-Ordner mit pyproject.toml," >&2
    echo "         setup.py oder setup.cfg, oder dieselben Metadaten in der" >&2
    echo "         Repo-Wurzel." >&2
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

# Beim Einzelpaket zaehlt jede geaenderte Datei: die Zuordnung ueber die erste
# Pfadkomponente gibt es dort nicht, das Paket IST das Repo. Genau daran
# scheitert der Umweg ueber PACKAGES='.' - die Schnittmenge enthaelt nie '.'.
# Die PACKAGES-Pruefung steht davor, damit eine explizit gesetzte Liste auch
# hier gewinnt.
if [[ -z "${PACKAGES:-}" ]] && root_is_package; then
  if [[ -n "$CHANGED_FILES" ]]; then
    printf '%s\n' '.'
  fi
  exit 0
fi

# Erste Pfadkomponente je geaenderter Datei = moeglicher Paketordner.
TOUCHED="$(cut -d/ -f1 <<<"$CHANGED_FILES" | sort -u)"

while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  if grep -qxF "$pkg" <<<"$TOUCHED"; then
    printf '%s\n' "$pkg"
  fi
done < <(all_packages)

exit 0
