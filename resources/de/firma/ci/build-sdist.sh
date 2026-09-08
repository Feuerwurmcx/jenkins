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

# Drei Wege, in dieser Reihenfolge:
#
#   1. python-build ('python3 -m build'). Das ist das Standard-Frontend; es
#      baut in einer isolierten Umgebung und installiert die build-requires
#      selbst nach.
#   2. Das in pyproject.toml deklarierte Backend direkt aufrufen (PEP 517).
#      Fuer Agents, auf denen python-build fehlt und nicht nachinstalliert
#      werden darf, aber setuptools da ist. Ohne Isolation: was unter
#      build-system.requires steht, muss schon installiert sein - hier wird
#      nichts aus dem Netz geholt.
#   3. 'setup.py sdist' als letzter Ausweg, nur fuer Pakete ganz ohne
#      pyproject.toml.
#
# Frueher fehlte Weg 2, und Weg 3 sprang fuer JEDES Paket ein, sobald
# python-build fehlte. Bei einem Paket, das nur eine pyproject.toml hat -
# der Normalfall bei src-Layout - scheiterte das mit "can't open file
# setup.py", obwohl setuptools alles hatte, was noetig war.
if python3 -c 'import build' 2>/dev/null; then
  ( cd "$PKG" && python3 -m build --sdist --outdir "$STAGE" ) >&2
elif [[ -f "$PKG/pyproject.toml" ]]; then
  echo "HINWEIS: python-build nicht installiert - rufe das Backend aus pyproject.toml direkt auf (PEP 517)" >&2
  (
    cd "$PKG" && python3 - "$STAGE" <<'PY'
import importlib
import os
import sys

outdir = sys.argv[1]

# tomllib gibt es erst ab Python 3.11; tomli ist dasselbe Modul davor. Fehlen
# beide, wird das Standard-Backend angenommen, statt hier aufzugeben - falsch
# liegt das nur bei einem Projekt mit exotischem Backend, und das faellt dann
# beim Import unten laut auf.
try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        tomllib = None

build_system = {}
if tomllib is not None:
    with open("pyproject.toml", "rb") as fh:
        build_system = tomllib.load(fh).get("build-system", {})
else:
    sys.stderr.write(
        "HINWEIS: weder tomllib (Python >= 3.11) noch tomli - nehme "
        "setuptools.build_meta als Backend an\n"
    )

# Der Default kommt aus PEP 517: fehlt build-backend, gilt das
# Legacy-Setuptools-Backend, das auch ein reines setup.py-Projekt baut.
backend_name = build_system.get("build-backend", "setuptools.build_meta:__legacy__")

# backend-path: ein Backend, das im Projekt selbst liegt (PEP 517).
for entry in build_system.get("backend-path", []):
    sys.path.insert(0, os.path.abspath(entry))

module_name, _, attribute = backend_name.partition(":")
try:
    backend = importlib.import_module(module_name)
except ImportError as exc:
    requires = build_system.get("requires", [])
    sys.stderr.write(
        "FEHLER: Backend '%s' aus pyproject.toml ist nicht importierbar (%s).\n"
        "        Ohne python-build wird nichts nachinstalliert - was unter\n"
        "        build-system.requires steht, muss auf dem Agent vorhanden\n"
        "        sein. Verlangt wird: %s\n" % (backend_name, exc, requires or "(nichts)")
    )
    raise SystemExit(1)
if attribute:
    backend = getattr(backend, attribute)

# Das Backend legt beim sdist-Bau *.egg-info im Quellbaum an. Im
# Jenkins-Workspace ist das folgenlos; python-build vermeidet es nur, weil es
# in eine Kopie baut.
sys.stderr.write("%s\n" % backend.build_sdist(outdir))
PY
  ) >&2
elif [[ -f "$PKG/setup.py" ]]; then
  echo "HINWEIS: python-build nicht installiert und keine pyproject.toml, nutze 'setup.py sdist'" >&2
  ( cd "$PKG" && python3 setup.py --quiet sdist --dist-dir "$STAGE" ) >&2
else
  echo "FEHLER: $PKG hat nur eine setup.cfg, aber weder pyproject.toml noch" >&2
  echo "        setup.py - und python-build ist nicht installiert. Ohne eines" >&2
  echo "        von beidem gibt es keinen Weg, daraus eine sdist zu bauen." >&2
  exit 1
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
