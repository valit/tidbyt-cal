#!/usr/bin/env bash
#
# push.sh — render my_calendar.star for each target device and push to Tidbyt.
#
# Target devices come from DEVICES_JSON (a JSON array of device names from the
# dispatch client_payload, passed by render.yml). If missing or null, all
# devices defined in config.json are targeted (manual/workflow_dispatch case).
#
# Device config (device_id, token_secret, calendars) is read from config.json.
# Calendar URLs are resolved from the environment using each calendar's
# url_secret name.

set -euo pipefail

CONFIG=config.json

# --- Install pixlet if needed (latest linux_amd64 release) ------------------
if ! command -v pixlet >/dev/null 2>&1; then
  echo "pixlet not found — installing latest linux_amd64 release..."
  # Fetch the whole API response first, then parse it. Parsing curl's output
  # through a pipe to an early-exiting tool (grep -m1 / head) makes curl die
  # with a write error, which pipefail would turn into a script failure.
  RELEASE_JSON="$(curl -sSL https://api.github.com/repos/tidbyt/pixlet/releases/latest)"
  VERSION="$(awk -F'"' '/"tag_name"/{print $4; exit}' <<<"$RELEASE_JSON")"
  VERSION="${VERSION#v}"
  echo "Installing pixlet v${VERSION}"
  curl -sSL "https://github.com/tidbyt/pixlet/releases/download/v${VERSION}/pixlet_${VERSION}_linux_amd64.tar.gz" \
    -o /tmp/pixlet.tar.gz
  mkdir -p /tmp/pixlet
  tar -xzf /tmp/pixlet.tar.gz -C /tmp/pixlet
  sudo mv /tmp/pixlet/pixlet /usr/local/bin/pixlet
  sudo chmod +x /usr/local/bin/pixlet
fi
pixlet version

# --- Determine target devices ------------------------------------------------
DEVICES_JSON="${DEVICES_JSON:-null}"
target_devices=()
if [ "$DEVICES_JSON" = "null" ] || [ -z "$DEVICES_JSON" ]; then
  echo "No DEVICES_JSON — defaulting to all devices in $CONFIG"
  while IFS= read -r name; do
    target_devices+=("$name")
  done < <(jq -r '.devices[].name' "$CONFIG")
else
  while IFS= read -r name; do
    target_devices+=("$name")
  done < <(echo "$DEVICES_JSON" | jq -r '.[]')
fi
echo "Target devices: ${target_devices[*]}"

# --- Timing overrides --------------------------------------------------------
prep_time="${PREP_TIME:-900}"
persistence_time="${PERSISTENCE_TIME:-600}"
extended_threshold="${EXTENDED_THRESHOLD:-14400}"

# --- Render and push each device ---------------------------------------------
for device_name in "${target_devices[@]}"; do
  echo ""
  echo "=== Device: $device_name ==="

  device_json=$(jq -r --arg name "$device_name" '.devices[] | select(.name == $name)' "$CONFIG")
  if [ -z "$device_json" ]; then
    echo "  ! Unknown device '$device_name' in $CONFIG — skipping"
    continue
  fi

  device_id=$(echo "$device_json" | jq -r '.device_id')
  token_secret=$(echo "$device_json" | jq -r '.token_secret')
  token="${!token_secret:-}"
  if [ -z "$token" ]; then
    echo "  ! Token secret $token_secret not set for $device_name — skipping"
    continue
  fi

  # Build calendar URL args (first calendar → ical_url, second → ical_url_2).
  # Calendars beyond the second are silently ignored (my_calendar.star only
  # supports two iCal feeds).
  pixlet_args=()
  cal_count=0
  while IFS= read -r cal_id; do
    url_secret=$(jq -r --arg id "$cal_id" '.calendars[] | select(.id == $id) | .url_secret' "$CONFIG")
    cal_url="${!url_secret:-}"
    if [ -z "$cal_url" ]; then
      echo "  ! Secret $url_secret not set for calendar '$cal_id' — skipping this calendar"
      continue
    fi
    cal_count=$((cal_count + 1))
    if [ "$cal_count" -eq 1 ]; then
      pixlet_args+=("ical_url=$cal_url")
    elif [ "$cal_count" -eq 2 ]; then
      pixlet_args+=("ical_url_2=$cal_url")
    fi
  done < <(echo "$device_json" | jq -r '.calendars[]')

  if [ "$cal_count" -eq 0 ]; then
    echo "  ! No valid calendar URLs for $device_name — skipping"
    continue
  fi

  pixlet_args+=(
    "prep_time=$prep_time"
    "persistence_time=$persistence_time"
    "extended_threshold=$extended_threshold"
  )

  echo "  Rendering my_calendar.star ($cal_count calendar(s))..."
  pixlet render my_calendar.star "${pixlet_args[@]}" -o my_calendar.webp

  echo "  Pushing to $device_id..."
  pixlet push "$device_id" my_calendar.webp -t "$token" -i helloCal
  echo "  Done."
done

echo ""
echo "All devices processed."
