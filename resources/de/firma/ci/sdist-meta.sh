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
MEMBER="$(tar tzf "$ARCHIVE" | grep -m1 '/PKG-INFO$' || true)"
[[ -n "$MEMBER" ]] || { echo "FEHLER: kein PKG-INFO in $ARCHIVE" >&2; exit 1; }

VALUE="$(tar xzOf "$ARCHIVE" "$MEMBER" | sed -n "s/^${KEY}: //p" | head -1)"

[[ -n "$VALUE" ]] || { echo "FEHLER: ${KEY} nicht in PKG-INFO von $ARCHIVE" >&2; exit 1; }
echo "$VALUE"
