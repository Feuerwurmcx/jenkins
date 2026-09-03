#!/usr/bin/env bash
# Lädt eine sdist in ein Nexus PyPI-HOSTED-Repository (twine).
#
#   NEXUS_URL=https://nexus.example.com NEXUS_PYPI_HOSTED=pypi-internal \
#   NEXUS_USER=... NEXUS_PASS=... ci/publish-pypi.sh <archiv>
#
# Zum LESEN nimmt man das Group-Repo (z.B. group_pypi), zum SCHREIBEN nie:
# ein Group-Repo aggregiert nur, es nimmt keine Uploads an.
#
# Zugangsdaten gehen über TWINE_USERNAME/TWINE_PASSWORD, also über die Umgebung
# und nicht über argv – dieselbe Überlegung wie bei curl --config -.
set -euo pipefail
set +x

ARCHIVE="${1:?archiv fehlt}"

: "${NEXUS_URL:?NEXUS_URL fehlt}"
: "${NEXUS_PYPI_HOSTED:?NEXUS_PYPI_HOSTED fehlt (HOSTED-Repo, nicht die Group!)}"
: "${NEXUS_USER:?NEXUS_USER fehlt}"
: "${NEXUS_PASS:?NEXUS_PASS fehlt}"

[[ -f "$ARCHIVE" ]] || { echo "FEHLER: $ARCHIVE nicht gefunden" >&2; exit 1; }

BASE="${NEXUS_URL%/}"
REPO_URL="${BASE}/repository/${NEXUS_PYPI_HOSTED}/"

# --- Schutz vor dem Klassiker: Upload gegen ein Group-Repo -------------------
# Die REST-API sagt uns den Typ. Ist sie nicht erreichbar (fehlende Rechte),
# wird nur gewarnt statt abzubrechen.
check_repo_type() {
  local json type
  json=$(printf 'user = "%s:%s"\n' "$NEXUS_USER" "$NEXUS_PASS" \
         | curl --config - --silent --fail \
                "${BASE}/service/rest/v1/repositories" 2>/dev/null) || {
    echo "HINWEIS: Repo-Typ nicht prüfbar (REST-API nicht erreichbar/keine Rechte)" >&2
    return 0
  }
  type=$(python3 -c '
import json,sys
name=sys.argv[1]
for r in json.load(sys.stdin):
    if r.get("name")==name:
        print(r.get("type",""), r.get("format",""))
        break
' "$NEXUS_PYPI_HOSTED" <<<"$json")
  case "$type" in
    "group "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist ein GROUP-Repo. Group-Repos nehmen" >&2
      echo "        keine Uploads an – NEXUS_PYPI_HOSTED auf das hosted-Repo" >&2
      echo "        setzen, das Mitglied der Group ist." >&2
      exit 3 ;;
    "proxy "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist ein PROXY-Repo, kein hosted." >&2
      exit 3 ;;
    "hosted pypi") : ;;
    "hosted "*)
      echo "FEHLER: '${NEXUS_PYPI_HOSTED}' ist hosted, aber kein PyPI-Format (${type})." >&2
      exit 3 ;;
    *) echo "HINWEIS: Repo '${NEXUS_PYPI_HOSTED}' in der API nicht gefunden" >&2 ;;
  esac
}
[[ "${SKIP_REPO_CHECK:-0}" == "1" ]] || check_repo_type

# --- Upload -----------------------------------------------------------------
echo "Upload -> ${REPO_URL}  ($(basename "$ARCHIVE"))"
export TWINE_USERNAME="$NEXUS_USER"
export TWINE_PASSWORD="$NEXUS_PASS"
export TWINE_REPOSITORY_URL="$REPO_URL"
export TWINE_NON_INTERACTIVE=1

set +e
OUTPUT=$(python3 -m twine upload --disable-progress-bar "$ARCHIVE" 2>&1)
RC=$?
set -e
printf '%s\n' "$OUTPUT"

if [[ $RC -ne 0 ]]; then
  # PyPI-hosted lehnt eine bereits vorhandene Version ab (400) – das ist fast
  # immer ein vergessener Version-Bump, kein Infrastrukturfehler.
  if grep -qiE '400|already exists|repository does not allow updating' <<<"$OUTPUT"; then
    echo "FEHLER: Version liegt bereits im Repo. Version im Paket erhöhen." >&2
    exit 2
  fi
  exit $RC
fi
echo "OK: $(basename "$ARCHIVE")"
