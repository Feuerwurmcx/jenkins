#!/usr/bin/env bash
# Listet die Pakete, die sich seit <base> geaendert haben - eines pro Zeile.
#
#   changed-packages.sh <base>
#
# Ein Paket ist ein Top-Level-Ordner mit pyproject.toml, setup.py oder
# __init__.py. Statt der Auto-Erkennung eine feste Liste:
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
  local d
  for d in */; do
    d="${d%/}"
    if [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/__init__.py" ]]; then
      printf '%s\n' "$d"
    fi
  done | sort -u
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
  if grep -qxF "$pkg" <<<"$TOUCHED"; then
    printf '%s\n' "$pkg"
  fi
done < <(all_packages)

exit 0
