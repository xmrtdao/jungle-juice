#!/data/data/com.termux/files/usr/bin/bash
# Spatial Probe v4 — WiFi zone mapper with JWT + Cloudflare tunnel support
# Walk to a location, run this, and it fingerprints the RF terrain.
#
# Usage:  bash probe.sh "North-East Corner"
#         bash probe.sh "Living Room"
#         bash probe.sh "Driveway"
#
# Install: pkg install termux-api jq

LABEL="${1:-unknown-location}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Auth tokens ──
HERMES_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZhd291dWd0endtZWp4cWtlcXFqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1Mjc2OTcxMiwiZXhwIjoyMDY4MzQ1NzEyfQ.QH0k26R2xbf4U5z6BmdYG1h_lkeNQ41zDjqL2zWxzxU"
CF_TOKEN_ID="bfa0d8f42b17d44a0243d386bd5b6a40.access"
CF_TOKEN_SECRET="d8019ca2afa236c55828904245bf147f60feb11fa781ea7c6b05daee665690dd"

# ── Targets in priority order ──
TARGETS=(
  "http://192.168.14.19:8082"   # spatial receiver (fastest, no auth)
  "http://192.168.14.19:8080"   # main relay
  "http://192.168.1.19:8082"    # alternate subnet
)

# Always try the tunnel last (requires auth)
TUNNEL_URL="https://relay.mobilemonero.com/relay/api/spatial/scan"

echo "== Spatial Probe: $LABEL =="
echo "   Timestamp: $TIMESTAMP"
echo ""

# ── 1. Scan WiFi ──
SCAN=$(termux-wifi-scaninfo 2>/dev/null)
if [ -z "$SCAN" ]; then
  echo "[!] Install termux-api: pkg install termux-api"
  echo "    Grant location permission in Android Settings."
  exit 1
fi

echo "$SCAN" | jq empty 2>/dev/null || { echo "[!] Invalid scan data"; exit 1; }

AP_COUNT=$(echo "$SCAN" | jq length 2>/dev/null || echo "?")
echo "   Visible networks: $AP_COUNT"

# ── 2. Build payload ──
PAYLOAD=$(jq -n \
  --arg agent "probe-$LABEL" \
  --arg type "spatial_probe" \
  --arg ts "$TIMESTAMP" \
  --arg label "$LABEL" \
  --argjson scan "$SCAN" \
  '{agent:$agent,type:$type,timestamp:$ts,location_label:$label,wifi_scan:$scan}')

echo "$PAYLOAD" > /sdcard/.radar-last-probe.json 2>/dev/null || true

# ── 3. Try direct targets ──
SENT=false
for TARGET in "${TARGETS[@]}"; do
  echo "   Trying $TARGET ..."
  HTTP_CODE=$(curl -s -w "%{http_code}" --connect-timeout 3 --max-time 5 \
    -X POST "$TARGET/api/spatial/scan" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "   [OK] Saved to $TARGET"
    SENT=true
    break
  fi
done

# ── 4. Try Cloudflare tunnel (with JWT + CF Access token) ──
if [ "$SENT" = false ]; then
  echo "   Trying Cloudflare tunnel..."
  HTTP_CODE=$(curl -s -w "%{http_code}" --connect-timeout 5 --max-time 10 \
    -X POST "$TUNNEL_URL" \
    -H "Content-Type: application/json" \
    -H "CF-Access-Client-Id: $CF_TOKEN_ID" \
    -H "CF-Access-Client-Secret: $CF_TOKEN_SECRET" \
    -H "Authorization: Bearer $HERMES_JWT" \
    -d "$PAYLOAD" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "   [OK] Saved via Cloudflare tunnel"
    SENT=true
  else
    echo "   [ ] Tunnel returned HTTP $HTTP_CODE"
  fi
fi

if [ "$SENT" = false ]; then
  echo ""
  echo "[!] Could not reach any server."
  echo "    Check laptop is on: curl http://192.168.14.19:8082/health"
  echo "    Saved probe data to /sdcard/.radar-last-probe.json"
  echo ""
  echo "    Tunnel: https://relay.mobilemonero.com/relay/api/spatial/scan"
  echo "    (Requires Cloudflare Access auth)"
  exit 1
fi

# ── 5. Show APs ──
echo ""
echo "   Access Points (sorted by signal):"
echo "$SCAN" | jq -r '
  sort_by(.rssi // 0 | tonumber? // 0) | reverse[:8] | .[] |
  "#" * ([((.rssi | tonumber? // 0) + 100) / 8 | floor, 1] | max) as $bars |
  "     \($bars) \(.rssi)dBm  \(.ssid // "?")"'
echo ""
echo "   Done. Zone \"$LABEL\" mapped."
echo "   Open http://localhost:8080/radar/radar.html"
