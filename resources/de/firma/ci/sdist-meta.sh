#!/usr/bin/env bash
# Liest Name/Version aus der PKG-INFO einer gebauten sdist.
#
#   sdist-meta.sh <archiv> [name|version]     (default: version)
#
# Zuverlässiger als den Dateinamen zu zerlegen: setuptools normalisiert Name
# und Version, und Paketnamen dürfen selbst Bindestriche enthalten.
set -euo pipefail

ARCHIVE="${1:?archiv fehlt}"
FIELD="${2:-version}"

[[ -f "$ARCHIVE" ]] || { echo "FEHLER: $ARCHIVE nicht gefunden" >&2; exit 1; }

case "$FIELD" in
  name)    KEY='Name' ;;
  version) KEY='Version' ;;
  *) echo "FEHLER: Feld muss 'name' oder 'version' sein" >&2; exit 1 ;;
esac

# Erst den exakten Member-Namen suchen, dann gezielt entpacken. Ein Glob im
# Extract-Aufruf ginge nicht portabel: GNU tar braucht dafuer --wildcards,
# BSD tar (macOS) kennt die Option nicht.
#
# Wie in build-sdist.sh: Listing und PKG-INFO je einmal vollstaendig in eine
# Variable lesen statt zu pipen, danach nur noch mit Herestrings (<<<)
# filtern. Unter 'set -o pipefail' bricht 'tar ... | grep/head/sed' mit
# "Write error: Broken pipe" ab, sobald der Leser vor dem Ende der
# Tar-Ausgabe aussteigt und tar (bzw. ein sed davor) danach in die
# geschlossene Pipe weiterschreibt - reproduzierbar mit einer PKG-INFO
# > 64 KB (siehe test/run-tests.sh). sed beendet sich deshalb unten selbst
# per 'q' nach dem ersten Treffer, statt sich auf ein nachgeschaltetes
# 'head -1' zu verlassen: bei einer zweiten, spaeter im Text beginnenden
# "Name: "/"Version: "-Zeile (z. B. in einem eingebetteten Changelog) waere
# genau das wieder derselbe Fehler, nur zwischen sed und head statt
# zwischen tar und grep/head.
LISTING="$(tar tzf "$ARCHIVE")"
MEMBER="$(grep -m1 '/PKG-INFO$' <<<"$LISTING" || true)"
[[ -n "$MEMBER" ]] || { echo "FEHLER: kein PKG-INFO in $ARCHIVE" >&2; exit 1; }

META="$(tar xzOf "$ARCHIVE" "$MEMBER")"
VALUE="$(sed -n "/^${KEY}: /{
s/^${KEY}: //p
q
}" <<<"$META")"

[[ -n "$VALUE" ]] || { echo "FEHLER: ${KEY} nicht in PKG-INFO von $ARCHIVE" >&2; exit 1; }
echo "$VALUE"
