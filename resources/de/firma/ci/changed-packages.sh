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
  if [[ -n "${PACKAGES:-}" ]]; then
    # Absichtlich ohne Quotes: PACKAGES ist eine durch Leerzeichen getrennte Liste.
    printf '%s\n' ${PACKAGES} | sort -u
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

CHANGED_FILES="$(git diff --name-only "$BASE" HEAD)"

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
