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
#
# Knobs (all optional):
#   JELLYFIN_IMAGE           image to run (default jellyfin/jellyfin:10.10.7)
#   JELLYFIN_DEV_PORT        host port (default 8096)
#   JELLYFIN_DEV_STATE       state dir: config, cache, music, env file
#   JELLYFIN_DEV_NAME        container name (default jellyamp-dev-jellyfin);
#                            set it together with PORT and STATE to run a
#                            second, independent instance
#   JELLYFIN_DEV_URL         provision an ALREADY RUNNING server at this URL
#                            instead of `docker run` (e.g. a CI service
#                            container). The library is still generated into
#                            $STATE/music; whoever started the server must have
#                            mounted that directory at JELLYFIN_DEV_MEDIA_PATH.
#   JELLYFIN_DEV_MEDIA_PATH  where the server sees the library (default
#                            /media/music)
#   JELLYFIN_DEV_LOUDNESS=0  skip the LUFS scan (NormalizationGain stays null)
#   JELLYFIN_DEV_OFFLINE=0   let the container resolve host names. By default
#                            it cannot (--dns 127.0.0.1): the artists are made
#                            up, and a chance MusicBrainz/AudioDB match would
#                            give them biographies, pictures and genres on a
#                            machine with internet access but not on one
#                            without, so tests would see two different
#                            libraries. (Not applied to a JELLYFIN_DEV_URL
#                            server, which this script does not start.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${JELLYFIN_DEV_STATE:-${TMPDIR:-/tmp}/jellyamp-dev-jellyfin}"
PORT="${JELLYFIN_DEV_PORT:-8096}"
IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:10.10.7}"
NAME="${JELLYFIN_DEV_NAME:-jellyamp-dev-jellyfin}"
EXTERNAL_URL="${JELLYFIN_DEV_URL:-}"
MEDIA_PATH="${JELLYFIN_DEV_MEDIA_PATH:-/media/music}"
LOUDNESS="${JELLYFIN_DEV_LOUDNESS:-1}"
OFFLINE="${JELLYFIN_DEV_OFFLINE:-1}"
URL="${EXTERNAL_URL:-http://localhost:${PORT}}"
URL="${URL%/}"
USER_NAME=demo
PASSWORD=demo
AUTH='MediaBrowser Client="dev-jellyfin", Device="script", DeviceId="dev-jellyfin-script", Version="1.0"'

if [[ "${1:-}" == "--down" ]]; then
  if [[ -z "$EXTERNAL_URL" ]]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$STATE"
  echo "stopped"
  exit 0
fi

mkdir -p "$STATE/config" "$STATE/cache"
python3 "$HERE/make-library.py" "$STATE/music"

if [[ -z "$EXTERNAL_URL" ]] && ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  DNS=()
  [[ "$OFFLINE" == "1" ]] && DNS=(--dns 127.0.0.1)
  docker run -d --name "$NAME" -p "${PORT}:8096" ${DNS[@]+"${DNS[@]}"} \
    -v "$STATE/config:/config" -v "$STATE/cache:/cache" -v "$STATE/music:${MEDIA_PATH}:ro" \
    "$IMAGE" >/dev/null
fi

echo -n "waiting for Jellyfin at $URL"
READY=0
for _ in $(seq 1 180); do
  if curl -fsS --noproxy '*' "$URL/System/Info/Public" >/dev/null 2>&1; then READY=1; break; fi
  echo -n "."; sleep 1
done
echo
if [[ "$READY" != 1 ]]; then
  echo "Jellyfin did not come up at $URL" >&2
  [[ -z "$EXTERNAL_URL" ]] && docker logs --tail 40 "$NAME" >&2 || true
  exit 1
fi

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
  # Default fetchers on purpose. Switching the remote metadata fetchers off
  # (TypeOptions with empty MetadataFetchers) also switches off the artist
  # refresh that aggregates genres from the albums, so artists would come back
  # with `Genres: []` — unlike any real server. Lookups for the made-up
  # artists are kept from succeeding by JELLYFIN_DEV_OFFLINE instead.
  api POST "/Library/VirtualFolders?name=Music&collectionType=music&refreshLibrary=true" \
    "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$MEDIA_PATH\"}]}}" "$TOKEN"
fi

tracks() { # python expression over the list of probed Audio items -> stdout
  api GET "/Items?includeItemTypes=Audio&recursive=true&limit=1000&userId=$USER_ID" '' "$TOKEN" \
    | json "(lambda items: $1)([i for i in d[\"Items\"] if i.get(\"AlbumId\")])"
}
task() { # task key, python expression over the task object `t` -> stdout
  api GET /ScheduledTasks '' "$TOKEN" | json "(lambda t: $2)([t for t in d if t[\"Key\"]==\"$1\"][0])"
}
without_gain() { # number of tracks + albums that have no NormalizationGain yet
  api GET "/Items?includeItemTypes=Audio,MusicAlbum&recursive=true&limit=2000&userId=$USER_ID" '' "$TOKEN" \
    | json 'len([i for i in d["Items"] if i.get("NormalizationGain") is None])'
}

EXPECTED="$(find "$STATE/music" -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.m4a' -o -name '*.ogg' \) | wc -l)"
echo -n "waiting for library scan ($EXPECTED tracks)"
COUNT=0
for _ in $(seq 1 180); do
  # Count only tracks whose tags were already probed (they have an album).
  COUNT="$(tracks 'len(items)')"
  [[ "$COUNT" -ge "$EXPECTED" ]] && break
  echo -n "."; sleep 2
done
echo " $COUNT"
if [[ "$COUNT" -lt "$EXPECTED" ]]; then
  echo "library scan incomplete: $COUNT of $EXPECTED tracks" >&2
  exit 1
fi
# The tracks show up long before the scan is done: albums are still being
# renamed from their folder name ("Quarry Songs (1978)") to their tag name and
# artists, genres and images are still being linked. Wait for the scan task.
echo -n "waiting for the scan task to finish"
for _ in $(seq 1 180); do
  [[ "$(task RefreshLibrary 't["State"]')" == "Idle" ]] && break
  echo -n "."; sleep 2
done
echo

# Loudness. Jellyfin only fills `NormalizationGain` (tracks and albums) when
# the library has "LUFS scan" enabled AND the "Audio Normalization" scheduled
# task has run; the normal library scan never measures anything. The task only
# measures items that have no value yet and touches nothing else, so this is
# idempotent and safe on a live server (item IDs and names stay). It must not
# overlap the library scan, though: album values written while the scan is
# still saving albums are lost — hence the wait above and the re-run below.
if [[ "$LOUDNESS" == "1" ]]; then
  UPDATE="$(api GET /Library/VirtualFolders '' "$TOKEN" | python3 -c '
import json, sys
for folder in json.load(sys.stdin):
    options = folder.get("LibraryOptions") or {}
    if folder.get("CollectionType") == "music" and not options.get("EnableLUFSScan"):
        options["EnableLUFSScan"] = True
        print(json.dumps({"Id": folder["ItemId"], "LibraryOptions": options}))
')"
  if [[ -n "$UPDATE" ]]; then
    echo "enabling LUFS scan on the music library"
    while IFS= read -r body; do
      api POST /Library/VirtualFolders/LibraryOptions "$body" "$TOKEN"
    done <<<"$UPDATE"
  fi
  MISSING="$(without_gain)"
  if [[ "$MISSING" != "0" ]]; then
    TASK_ID="$(task AudioNormalization 't["Id"]')"
    echo -n "measuring loudness ($MISSING items)"
    for _ in $(seq 1 180); do
      if [[ "$(task AudioNormalization 't["State"]')" == "Idle" ]]; then
        MISSING="$(without_gain)"
        [[ "$MISSING" == "0" ]] && break
        api POST "/ScheduledTasks/Running/$TASK_ID" '' "$TOKEN"
      fi
      echo -n "."; sleep 2
    done
    echo
    if [[ "$MISSING" != "0" ]]; then
      echo "loudness scan incomplete: $MISSING items without NormalizationGain" >&2
      exit 1
    fi
  fi
fi

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
