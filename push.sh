#!/usr/bin/env bash
#
# push.sh — render the Tidbyt app and push it to both devices.
# Designed to run on a fresh Ubuntu GitHub Actions runner (installs pixlet
# if it isn't already on PATH), but also works locally on Linux.
#
# Required environment variables:
#   ICAL_URL       — private Google Calendar iCal feed URL
#   TIDBYT_TOKEN_1 — API token for device 1
#   TIDBYT_TOKEN_2 — API token for device 2

set -euo pipefail

: "${ICAL_URL:?ICAL_URL is not set}"

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

# --- Render ----------------------------------------------------------------
echo "Rendering my_calendar.star..."
pixlet render my_calendar.star ical_url="$ICAL_URL" -o my_calendar.webp

# --- Push to both devices --------------------------------------------------
echo "Pushing to device 1..."
pixlet push honestly-winning-pet-bulbul-3b3 my_calendar.webp -t "$TIDBYT_TOKEN_1" -i helloCal

echo "Pushing to device 2..."
pixlet push insecurely-valued-forgiving-salamander-ca7 my_calendar.webp -t "$TIDBYT_TOKEN_2" -i helloCal

echo "Done."
