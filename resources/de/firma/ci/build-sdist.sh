#!/usr/bin/env bash
# Baut aus einem Paketordner eine echte sdist (PyPI-tauglich) nach dist/.
#
#   build-sdist.sh <paket>        -> gibt den Archivpfad auf stdout aus
#
# Unterschied zu einem einfachen `tar czf`: das erzeugt ein beliebiges Archiv.
# Ein PyPI-Repo braucht eine sdist mit PKG-INFO und dem Wurzelverzeichnis
# <name>-<version>/.
#
# WICHTIG: Der Dateiname der sdist kommt aus den Metadaten, nicht aus dem
# Ordnernamen. Beides kann abweichen:
#   Ordner  alpha        name="Mein.Tolles_Paket"  -> mein_tolles_paket-...
#   Version 1.0-1                                  -> 1.0.post1  (PEP-440-normalisiert)
# Deshalb wird in ein leeres Unterverzeichnis gebaut und das Ergebnis von dort
# übernommen, statt nach <ordner>-*.tar.gz zu suchen.
set -euo pipefail

PKG="${1:?paket fehlt}"
OUT_DIR="${OUT_DIR:-dist}"

[[ -d "$PKG" ]] || { echo "FEHLER: $PKG ist kein Verzeichnis" >&2; exit 1; }
[[ -f "$PKG/setup.py" || -f "$PKG/setup.cfg" || -f "$PKG/pyproject.toml" ]] || {
  echo "FEHLER: $PKG hat keine Paket-Metadaten (setup.py/setup.cfg/pyproject.toml)" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
ABS_OUT="$(cd "$OUT_DIR" && pwd)"
STAGE="$(mktemp -d "${ABS_OUT}/.build-${PKG//\//_}-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if python3 -c 'import build' 2>/dev/null; then
  ( cd "$PKG" && python3 -m build --sdist --outdir "$STAGE" ) >&2
else
  echo "HINWEIS: python-build nicht installiert, nutze 'setup.py sdist'" >&2
  ( cd "$PKG" && python3 setup.py --quiet sdist --dist-dir "$STAGE" ) >&2
fi

mapfile -t BUILT < <(find "$STAGE" -maxdepth 1 -name '*.tar.gz' -print)
if [[ ${#BUILT[@]} -ne 1 ]]; then
  echo "FEHLER: erwartet genau eine sdist in $PKG, gefunden: ${#BUILT[@]}" >&2
  exit 1
fi
ARCHIVE="${BUILT[0]}"

# Gegenprobe: gültige sdist?
tar tzf "$ARCHIVE" | grep -q '/PKG-INFO$' || {
  echo "FEHLER: $(basename "$ARCHIVE") enthält kein PKG-INFO – keine gültige sdist" >&2
  exit 1
}

# Metadaten fürs Log – so sieht man sofort, wenn Ordner != Paketname
# Siehe sdist-meta.sh: exakter Member statt Glob, wegen BSD tar.
PKGINFO_MEMBER="$(tar tzf "$ARCHIVE" | grep -m1 '/PKG-INFO$')"
META="$(tar xzOf "$ARCHIVE" "$PKGINFO_MEMBER" | head -40)"
DIST_NAME="$(printf '%s\n' "$META" | sed -n 's/^Name: //p' | head -1)"
DIST_VER="$(printf '%s\n' "$META" | sed -n 's/^Version: //p' | head -1)"
echo "Ordner '${PKG}' -> ${DIST_NAME} ${DIST_VER}" >&2

mv -f "$ARCHIVE" "${ABS_OUT}/"
echo "${OUT_DIR}/$(basename "$ARCHIVE")"
