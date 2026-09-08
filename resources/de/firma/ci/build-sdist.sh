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

# sys.path[0] ist bei 'python3 -' das aktuelle Verzeichnis, also der
# Paketordner - er stuende damit VOR site-packages. Ein Modul im Projekt, das
# so heisst wie eines, das das Backend importiert (z. B. ein Ordner
# 'packaging/'), wuerde das Backend sprengen. python-build und
# pyproject_hooks tun das ausdruecklich nicht, also hier auch nicht.
if sys.path and sys.path[0] in ("", os.getcwd()):
    del sys.path[0]


def abbruch(text):
    sys.stderr.write(text.rstrip() + "\n")
    raise SystemExit(1)


# tomllib gibt es erst ab Python 3.11; tomli ist dasselbe Modul davor.
# Fehlen beide, wird NICHT geraten: welches Backend gilt, steht nur in der
# pyproject.toml. Ein angenommenes setuptools baut ein Poetry- oder
# Hatch-Projekt zwar oft ohne Fehler durch - aber unter falschem Namen und
# mit Version 0.0.0, und publish-pypi.sh laedt das anschliessend hoch.
try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        abbruch(
            "FEHLER: pyproject.toml ist nicht lesbar - weder tomllib (Python\n"
            "        >= 3.11) noch tomli sind vorhanden. Welches Build-Backend\n"
            "        gilt, steht nur in dieser Datei; geraten wird hier nicht.\n"
            "        Abhilfe: python-build installieren, oder tomli, oder\n"
            "        Python >= 3.11 verwenden."
        )

try:
    with open("pyproject.toml", "rb") as fh:
        pyproject = tomllib.load(fh)
except (OSError, ValueError) as exc:
    abbruch("FEHLER: pyproject.toml ist nicht lesbar: %s" % exc)

build_system = pyproject.get("build-system", {})

# Der Default kommt aus PEP 517: fehlt build-backend, gilt das
# Legacy-Setuptools-Backend, das auch ein reines setup.py-Projekt baut.
backend_name = build_system.get("build-backend", "setuptools.build_meta:__legacy__")
requires = build_system.get("requires", [])

# Ohne Isolation wird nichts nachinstalliert - also vorher pruefen, ob da ist,
# was das Projekt verlangt. Sonst baut ein zu altes setuptools ein Archiv, das
# aussieht wie eine sdist, aber "UNKNOWN-0.0.0" heisst; ein reiner
# ImportError-Fang unten sieht das nicht, weil der Import ja gelingt.
def verteilungsname(anforderung):
    name = ""
    for zeichen in anforderung.strip():
        if zeichen.isalnum() or zeichen in "._-":
            name += zeichen
        else:
            break
    return name


fehlend = []
ungeprueft = []
try:
    from packaging.requirements import Requirement  # oft nicht installiert
except ModuleNotFoundError:
    Requirement = None

try:
    from importlib.metadata import PackageNotFoundError, version as installierte_version
except ModuleNotFoundError:  # Python < 3.8
    PackageNotFoundError = None

if PackageNotFoundError is not None:
    for anforderung in requires:
        if Requirement is not None:
            req = Requirement(anforderung)
            if req.marker is not None and not req.marker.evaluate():
                continue   # gilt fuer diese Umgebung gar nicht
            name, spezifikation = req.name, req.specifier
        else:
            if ";" in anforderung:
                # Umgebungsmarker koennen wir ohne packaging nicht auswerten -
                # lieber ueberspringen als faelschlich blockieren.
                ungeprueft.append(anforderung)
                continue
            name, spezifikation = verteilungsname(anforderung), None
        if not name:
            continue
        try:
            vorhanden = installierte_version(name)
        except PackageNotFoundError:
            fehlend.append("%s (nicht installiert)" % anforderung)
            continue
        if spezifikation is not None and vorhanden not in spezifikation:
            fehlend.append("%s (installiert: %s)" % (anforderung, vorhanden))

if fehlend:
    abbruch(
        "FEHLER: build-system.requires aus pyproject.toml ist nicht erfuellt.\n"
        "        Ohne python-build wird nichts nachinstalliert, und ein Bau mit\n"
        "        den falschen Werkzeugen ergibt still ein falsches Archiv\n"
        "        (typisch: UNKNOWN-0.0.0).\n"
        "        Es fehlt: %s" % ", ".join(fehlend)
    )
if ungeprueft:
    sys.stderr.write(
        "HINWEIS: ohne das Modul 'packaging' nicht pruefbar (Umgebungsmarker): "
        "%s\n" % ", ".join(ungeprueft)
    )
if Requirement is None and requires:
    sys.stderr.write(
        "HINWEIS: ohne das Modul 'packaging' wurde nur geprueft, OB die "
        "build-requires installiert sind, nicht in welcher Version\n"
    )

# backend-path: ein Backend, das im Projekt selbst liegt (PEP 517).
for eintrag in build_system.get("backend-path", []):
    sys.path.insert(0, os.path.abspath(eintrag))

modulname, _, attribut = backend_name.partition(":")
try:
    backend = importlib.import_module(modulname)
except ImportError as exc:
    abbruch(
        "FEHLER: Backend '%s' aus pyproject.toml ist nicht importierbar (%s).\n"
        "        Ohne python-build wird nichts nachinstalliert - was unter\n"
        "        build-system.requires steht, muss auf dem Agent vorhanden\n"
        "        sein. Verlangt wird: %s" % (backend_name, exc, requires or "(nichts)")
    )
if attribut:
    backend = getattr(backend, attribut)

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
