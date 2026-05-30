#!/data/data/com.termux/files/usr/bin/bash
# WiFi Radar Scanner v1 — continuous multi-AP signal mapper
# Runs on Android in Termux. Scans all visible WiFi networks every 2 seconds
# and streams the data to the radar system. Walk around and watch signals change.
#
# Usage:  bash wifi-radar.sh
#         bash wifi-radar.sh --rate 1   (scan every 1 second)
#         bash wifi-radar.sh --once     (single scan, then exit)
#
# The radar dashboard at http://localhost:8080/radar/radar.html
# will show live multi-AP signal data as you move.

# ── Config ──
RELAY_URL="http://192.168.14.19:8082"
TUNNEL_URL="https://relay.mobilemonero.com/relay/api/spatial/scan"
SCAN_RATE=2  # seconds between scans

# ── Auth (for Cloudflare tunnel) ──
HERMES_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZhd291dWd0endtZWp4cWtlcXFqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1Mjc2OTcxMiwiZXhwIjoyMDY4MzQ1NzEyfQ.QH0k26R2xbf4U5z6BmdYG1h_lkeNQ41zDjqL2zWxzxU"
CF_ID="bfa0d8f42b17d44a0243d386bd5b6a40.access"
CF_SECRET="d8019ca2afa236c55828904245bf147f60feb11fa781ea7c6b05daee665690dd"

# ── Parse args ──
while [ $# -gt 0 ]; do
  case "$1" in
    --rate) SCAN_RATE="$2"; shift 2 ;;
    --once) SCAN_RATE=0; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# ── Check deps ──
if ! command -v termux-wifi-scaninfo &>/dev/null; then
  echo "[!] Install termux-api: pkg install termux-api"
  echo "    Also grant location permission in Android Settings."
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "[!] Install jq: pkg install jq"
  exit 1
fi

echo "=============================================="
echo "  WiFi Radar Scanner"
echo "  Scanning every ${SCAN_RATE}s ..."
echo "  Sending to: $RELAY_URL"
echo "  Phone must be on same WiFi as laptop"
echo "=============================================="
echo ""

COUNT=0
LAST_APS=""
STABLE_COUNT=0

send_scan() {
  local SCAN="$1"
  local TS="$2"
  local LABEL="$3"

  # Build payload with jq
  local PAYLOAD
  PAYLOAD=$(echo "$SCAN" | jq -n \
    --arg agent "wifi-radar" \
    --arg type "continuous_scan" \
    --arg ts "$TS" \
    --arg label "$LABEL" \
    --argjson scan "$SCAN" \
    '{agent:$agent,type:$type,timestamp:$ts,location_label:$label,wifi_scan:$scan}' 2>/dev/null)

  [ -z "$PAYLOAD" ] && return 1

  # Try direct first
  local CODE
  CODE=$(curl -s -w "%{http_code}" --connect-timeout 2 --max-time 4 \
    -X POST "$RELAY_URL/api/spatial/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)

  if [ "$CODE" = "200" ]; then
    return 0
  fi

  # Try tunnel
  CODE=$(curl -s -w "%{http_code}" --connect-timeout 3 --max-time 6 \
    -X POST "$TUNNEL_URL" \
    -H "Content-Type: application/json" \
    -H "CF-Access-Client-Id: $CF_ID" \
    -H "CF-Access-Client-Secret: $CF_SECRET" \
    -H "Authorization: Bearer $HERMES_JWT" \
    -d "$PAYLOAD" 2>/dev/null)

  [ "$CODE" = "200" ]
}

# ── Main loop ──
while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Scan
  SCAN=$(termux-wifi-scaninfo 2>/dev/null)
  if [ -z "$SCAN" ]; then
    echo "[$(date +%H:%M:%S)] [!] Scan failed — check location permissions"
    sleep "$SCAN_RATE"
    continue
  fi

  # Validate
  if ! echo "$SCAN" | jq -e '. | type == "array"' >/dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)] [!] Invalid scan data:"
    echo "$SCAN" | head -5
    echo ""
    echo "    Make sure location permission is granted to Termux."
    echo "    Settings -> Apps -> Termux -> Permissions -> Location = ON"
    sleep "$SCAN_RATE"
    continue
  fi

  COUNT=$((COUNT + 1))

  # Count APs
  AP_COUNT=$(echo "$SCAN" | jq length 2>/dev/null || echo "0")

  # Send to server
  if send_scan "$SCAN" "$TS" "continuous"; then
    STATUS="SENT"
  else
    STATUS="FAIL"
  fi

  # Display top APs
  echo "[$(date +%H:%M:%S)] Scan #$COUNT | $AP_COUNT APs | $STATUS"
  echo "$SCAN" | jq -r '
    sort_by(.rssi // 0 | tonumber? // 0) | reverse[:5] | .[] |
    "  \(.rssi // "?")dBm  \(.ssid // "?") (ch\(.channel // "?"))"' 2>/dev/null

  # Detect movement: if APs changed significantly, note it
  CURRENT_APS=$(echo "$SCAN" | jq -r '[.[].bssid] | sort | join(",")' 2>/dev/null)
  if [ "$CURRENT_APS" != "$LAST_APS" ] && [ -n "$LAST_APS" ]; then
    echo "  >>> Environment change detected"
    STABLE_COUNT=0
  else
    STABLE_COUNT=$((STABLE_COUNT + 1))
  fi
  LAST_APS="$CURRENT_APS"

  echo ""

  # Exit if --once
  [ "$SCAN_RATE" = "0" ] && break

  sleep "$SCAN_RATE"
done
