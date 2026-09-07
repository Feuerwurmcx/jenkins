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

# Kein 'mapfile': das ist ein Bash-4-Builtin und existiert unter macOS'
# /bin/bash 3.2 nicht (rc 127). Stattdessen portabel per -print0/read -d ''
# in einer Prozess-Substitution (keine Pipe, sonst liefe die Schleife wegen
# 'set -o pipefail' in einer Subshell und BUILT bliebe danach leer) fuellen -
# das funktioniert auch bei Dateinamen mit Leerzeichen.
BUILT=()
while IFS= read -r -d '' f; do
  BUILT+=("$f")
done < <(find "$STAGE" -maxdepth 1 -name '*.tar.gz' -print0)
if [[ ${#BUILT[@]} -ne 1 ]]; then
  echo "FEHLER: erwartet genau eine sdist in $PKG, gefunden: ${#BUILT[@]}" >&2
  exit 1
fi
ARCHIVE="${BUILT[0]}"

# Gegenprobe: gültige sdist?
# Kein 'tar tzf | grep' und kein 'tar xzOf | ...': unter 'set -o pipefail'
# bricht tar mit "Write error: Broken pipe" (rc 1) ab, sobald der Leser
# dahinter (grep -q/-m1, frueher auch 'head -40') vor dem Ende von tars
# Ausgabe aussteigt und tar danach in die geschlossene Pipe weiterschreibt.
# Mit bsdtar reproduzierbar bei einer PKG-INFO > 64 KB (siehe
# test/run-tests.sh); auf Linux (GNU tar/GNU grep) faellt vermutlich schon
# ein grosses Listing (viele Dateien in der sdist) genauso um. Deshalb
# Listing und PKG-INFO je einmal vollstaendig in eine Variable lesen und
# danach nur noch mit Herestrings (<<<) filtern - da liest niemand von einem
# Prozess, der vorzeitig aussteigen und einen Schreibfehler ausloesen kann.
LISTING="$(tar tzf "$ARCHIVE")"
grep -q '/PKG-INFO$' <<<"$LISTING" || {
  echo "FEHLER: $(basename "$ARCHIVE") enthält kein PKG-INFO – keine gültige sdist" >&2
  exit 1
}

# Metadaten fürs Log – so sieht man sofort, wenn Ordner != Paketname
# Siehe sdist-meta.sh: exakter Member statt Glob, wegen BSD tar.
PKGINFO_MEMBER="$(grep -m1 '/PKG-INFO$' <<<"$LISTING")"
META="$(tar xzOf "$ARCHIVE" "$PKGINFO_MEMBER")"
# sed beendet sich hier selbst per 'q' nach dem ersten Treffer, statt sich
# auf ein nachgeschaltetes 'head -1' zu verlassen: kaeme aus der Description
# eine zweite Zeile, die mit "Name: "/"Version: " beginnt (z. B. ein
# eingebettetes Changelog), wuerde 'sed | head -1' aus demselben Grund wie
# oben scheitern, sobald head schon zu ist und sed den zweiten Treffer noch
# schreiben will.
DIST_NAME="$(sed -n '/^Name: /{
s/^Name: //p
q
}' <<<"$META")"
DIST_VER="$(sed -n '/^Version: /{
s/^Version: //p
q
}' <<<"$META")"
# Bei '.' ist das Repo selbst das Paket - "Ordner '.'" waere missverstaendlich.
if [[ "$PKG" == "." ]]; then
  echo "Repo-Wurzel -> ${DIST_NAME} ${DIST_VER}" >&2
else
  echo "Ordner '${PKG}' -> ${DIST_NAME} ${DIST_VER}" >&2
fi

mv -f "$ARCHIVE" "${ABS_OUT}/"
echo "${OUT_DIR}/$(basename "$ARCHIVE")"
