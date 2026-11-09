#!/usr/bin/env bash
# Start a throwaway Jellyfin server with a synthetic music library and a known
# user, for integration tests, UI tests and screenshots.
#
#   scripts/dev-jellyfin/up.sh            # start (idempotent), prints env
#   scripts/dev-jellyfin/up.sh --down     # stop and delete all state
#
# Result (also written to $STATE/env):
#   JELLYFIN_URL=http://localhost:8096  JELLYFIN_USER=demo  JELLYFIN_PASSWORD=demo
#   JELLYFIN_API_KEY=<key for jellyamp-server>  JELLYFIN_USER_ID=<id>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${JELLYFIN_DEV_STATE:-${TMPDIR:-/tmp}/jellyamp-dev-jellyfin}"
PORT="${JELLYFIN_DEV_PORT:-8096}"
IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:10.10.7}"
NAME="jellyamp-dev-jellyfin"
URL="http://localhost:${PORT}"
USER_NAME=demo
PASSWORD=demo
AUTH='MediaBrowser Client="dev-jellyfin", Device="script", DeviceId="dev-jellyfin-script", Version="1.0"'

if [[ "${1:-}" == "--down" ]]; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$STATE"
  echo "stopped"
  exit 0
fi

mkdir -p "$STATE/config" "$STATE/cache"
python3 "$HERE/make-library.py" "$STATE/music"

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" -p "${PORT}:8096" \
    -v "$STATE/config:/config" -v "$STATE/cache:/cache" -v "$STATE/music:/media/music:ro" \
    "$IMAGE" >/dev/null
fi

echo -n "waiting for Jellyfin"
for _ in $(seq 1 120); do
  if curl -fsS --noproxy '*' "$URL/System/Info/Public" >/dev/null 2>&1; then break; fi
  echo -n "."; sleep 1
done
echo

api() { # method path [json-body] [token]
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local auth="$AUTH"
  [[ -n "$token" ]] && auth="$AUTH, Token=\"$token\""
  if [[ -n "$body" ]]; then
    curl -fsS --noproxy '*' -X "$method" "$URL$path" -H "Authorization: $auth" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -fsS --noproxy '*' -X "$method" "$URL$path" -H "Authorization: $auth"
  fi
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

if [[ "$(api GET /System/Info/Public | json 'd.get("StartupWizardCompleted")')" != "True" ]]; then
  echo "completing startup wizard"
  for _ in $(seq 1 60); do api GET /Startup/Configuration >/dev/null 2>&1 && break; sleep 1; done
  api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
  api GET /Startup/User >/dev/null
  api POST /Startup/User "{\"Name\":\"$USER_NAME\",\"Password\":\"$PASSWORD\"}"
  api POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
  api POST /Startup/Complete
fi

LOGIN="$(api POST /Users/AuthenticateByName "{\"Username\":\"$USER_NAME\",\"Pw\":\"$PASSWORD\"}")"
TOKEN="$(echo "$LOGIN" | json 'd["AccessToken"]')"
USER_ID="$(echo "$LOGIN" | json 'd["User"]["Id"]')"

if [[ "$(api GET /Library/VirtualFolders '' "$TOKEN" | json 'len(d)')" == "0" ]]; then
  echo "adding music library"
  api POST "/Library/VirtualFolders?name=Music&collectionType=music&refreshLibrary=true" \
    '{"LibraryOptions":{"PathInfos":[{"Path":"/media/music"}]}}' "$TOKEN"
fi

EXPECTED="$(find "$STATE/music" -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.m4a' -o -name '*.ogg' \) | wc -l)"
echo -n "waiting for library scan ($EXPECTED tracks)"
for _ in $(seq 1 180); do
  # Count only tracks whose tags were already probed (they have an album).
  COUNT="$(api GET "/Items?includeItemTypes=Audio&recursive=true&limit=1000&userId=$USER_ID" '' "$TOKEN" | json 'len([i for i in d["Items"] if i.get("AlbumId")])')"
  [[ "$COUNT" -ge "$EXPECTED" ]] && break
  echo -n "."; sleep 2
done
echo " $COUNT"

if [[ "$(api GET /Auth/Keys '' "$TOKEN" | json 'len([k for k in d["Items"] if k["AppName"]=="jellyamp-server"])')" == "0" ]]; then
  api POST "/Auth/Keys?app=jellyamp-server" '' "$TOKEN"
fi
API_KEY="$(api GET /Auth/Keys '' "$TOKEN" | json '[k for k in d["Items"] if k["AppName"]=="jellyamp-server"][0]["AccessToken"]')"

cat > "$STATE/env" <<ENV
JELLYFIN_URL=$URL
JELLYFIN_USER=$USER_NAME
JELLYFIN_PASSWORD=$PASSWORD
JELLYFIN_USER_ID=$USER_ID
JELLYFIN_API_KEY=$API_KEY
ENV
cat "$STATE/env"
