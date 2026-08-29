#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  android/adb-demo.sh — Live ADB commands for the presentation demo
#
#  Commands:
#    enroll     Install Headwind MDM agent + open enrollment screen
#    info       Show device security info (encryption, admin, etc.)
#    mitm       Configure emulator proxy → mitmproxy (show the attack)
#    mitm-mdm   Same attack, but pushed via the HMDM server REST API (realistic demo)
#    vpn        Remove proxy (simulate VPN defence kicking in)
#    lock       Lock the device screen immediately
#    audit      List apps + permissions audit
#    wipe       Factory reset the emulator (DESTRUCTIVE — demo use only)
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[-]${NC} $1"; exit 1; }
section(){ echo -e "\n${BLUE}── $1 ──────────────────────────${NC}"; }

HOST_IP="10.0.2.2"          # emulator's alias for host machine
HMDM_PORT="8080"
MITM_PORT="8081"
HMDM_URL="http://${HOST_IP}:${HMDM_PORT}"
HMDM_API="http://localhost:${HMDM_PORT}"
HMDM_USER="admin"
HMDM_PASS_MD5="0192023A7BBD73250516F069DF18B500"   # MD5("admin123").toUpperCase()
DEVICE_NUMBER="DEMO001"

adb_check() {
    adb devices | grep -q "emulator" || error "No emulator running. Start one first: ./avd-setup.sh start"
}

# ── enroll ────────────────────────────────────────────────────────────────────
cmd_enroll() {
    adb_check
    section "Headwind MDM Agent Enrollment"

    AGENT_APK="hmdm-agent.apk"
    if [ ! -f "$AGENT_APK" ]; then
        warn "hmdm-agent.apk not found locally."
        log "Download from:  http://localhost:8080  → Devices → Download agent"
        log "Or pull directly with adb if already installed."
        warn "Skipping APK install step."
    else
        log "Installing Headwind MDM agent..."
        adb install -r "$AGENT_APK" && log "Agent installed." || warn "Install failed."
    fi

    log "Opening HMDM enrollment URL in browser on emulator..."
    adb shell am start -a android.intent.action.VIEW \
        -d "${HMDM_URL}/open-mdm-app-google" 2>/dev/null || \
        log "Open this URL on the emulator: ${HMDM_URL}"

    log "In the HMDM admin panel → Devices → Add Device to get enrollment QR/code."
}

# ── info ──────────────────────────────────────────────────────────────────────
cmd_info() {
    adb_check
    section "Device Security Information"

    echo -e "\n${GREEN}Encryption:${NC}"
    ENC=$(adb shell getprop ro.crypto.state 2>/dev/null)
    echo "  ro.crypto.state = $ENC"
    [ "$ENC" = "encrypted" ] && log "Full-disk encryption: ENABLED" || warn "Encryption: $ENC"

    echo -e "\n${GREEN}Android version:${NC}"
    adb shell getprop ro.build.version.release 2>/dev/null | xargs echo "  Android"
    adb shell getprop ro.build.version.sdk 2>/dev/null | xargs echo "  API level"

    echo -e "\n${GREEN}Security patch:${NC}"
    adb shell getprop ro.build.version.security_patch 2>/dev/null | xargs echo "  Patch date"

    echo -e "\n${GREEN}USB debugging:${NC}"
    USB=$(adb shell settings get global adb_enabled 2>/dev/null)
    [ "$USB" = "1" ] && warn "  USB debugging ENABLED (should be OFF on real device)" || log "  USB debugging disabled"

    echo -e "\n${GREEN}Unknown sources (sideload):${NC}"
    UNK=$(adb shell settings get secure install_non_market_apps 2>/dev/null)
    [ "$UNK" = "1" ] && warn "  Unknown sources ENABLED (attack risk)" || log "  Unknown sources disabled"

    echo -e "\n${GREEN}Device admin apps (MDM):${NC}"
    adb shell dumpsys device_policy 2>/dev/null | grep "Active admin" | sed 's/^/  /'

    echo -e "\n${GREEN}Screen lock type:${NC}"
    adb shell dumpsys lock_settings 2>/dev/null | grep -i "quality\|method" | head -5 | sed 's/^/  /'

    echo -e "\n${GREEN}Network proxy:${NC}"
    PROXY_HOST=$(adb shell settings get global http_proxy 2>/dev/null)
    [ -n "$PROXY_HOST" ] && echo "  Proxy: $PROXY_HOST" || echo "  No proxy configured"
}

# ── hmdm_auth — authenticate and return session cookie file ──────────────────
hmdm_auth() {
    local cookie_file="$1"
    local response
    response=$(curl -s -c "$cookie_file" \
        -X POST "${HMDM_API}/rest/public/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"login\":\"${HMDM_USER}\",\"password\":\"${HMDM_PASS_MD5}\"}")
    if echo "$response" | grep -q '"status":"OK"'; then
        return 0
    else
        return 1
    fi
}

# ── mitm-mdm (realistic attack via MDM API) ───────────────────────────────────
cmd_mitm_mdm() {
    adb_check
    section "MITM Attack Demo — Policy Pushed via MDM Server API"

    COOKIE_FILE=$(mktemp /tmp/hmdm-session-XXXXXX)
    trap "rm -f $COOKIE_FILE" EXIT

    # Step 1: Authenticate with the HMDM server
    warn "SIMULATING ATTACK: rogue MDM admin authenticating to server..."
    if ! hmdm_auth "$COOKIE_FILE"; then
        error "Failed to authenticate with HMDM server at ${HMDM_API}"
    fi
    log "Authenticated to HMDM server as '${HMDM_USER}'"

    # Step 2: Resolve device ID from device number
    DEVICE_JSON=$(curl -s -b "$COOKIE_FILE" \
        "${HMDM_API}/rest/private/devices/number/${DEVICE_NUMBER}")
    DEVICE_ID=$(echo "$DEVICE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['id'])" 2>/dev/null)
    if [ -z "$DEVICE_ID" ]; then
        error "Device '${DEVICE_NUMBER}' not found in HMDM. Is the device enrolled?"
    fi
    log "Found device: ${DEVICE_NUMBER} (id=${DEVICE_ID})"

    # Step 3: Push a configUpdated notification via the HMDM push API
    log "Pushing silent policy update to device via HMDM API..."
    PUSH_RESPONSE=$(curl -s -b "$COOKIE_FILE" \
        -X POST "${HMDM_API}/rest/private/push" \
        -H "Content-Type: application/json" \
        -d "{
              \"messageType\": \"configUpdated\",
              \"deviceNumbers\": [\"${DEVICE_NUMBER}\"],
              \"broadcast\": false
            }")
    if echo "$PUSH_RESPONSE" | grep -q '"status":"OK"'; then
        log "Policy push delivered via MQTT — device is syncing..."
    else
        warn "Push returned: $PUSH_RESPONSE"
    fi

    # Step 4: Exercise device-owner access to apply the proxy
    # (In a real malicious MDM, this happens inside the agent after config sync)
    log "MDM agent applying proxy policy (device-owner privilege)..."
    adb shell settings put global http_proxy "${HOST_IP}:${MITM_PORT}"
    log "Proxy set → ${HOST_IP}:${MITM_PORT}"

    echo ""
    echo "  Attack chain:"
    echo "    1. Attacker called HMDM REST API  →  authenticated as MDM admin"
    echo "    2. HMDM pushed configUpdated      →  device received silent MQTT push"
    echo "    3. MDM agent (device owner)       →  applied proxy policy silently"
    echo ""
    log "Browse http:// sites on the emulator — watch traffic at: http://localhost:8082"
    echo ""
    echo "  To restore (simulate VPN defence):  $0 vpn"
}

# ── mitm (attack demo) ────────────────────────────────────────────────────────
cmd_mitm() {
    adb_check
    section "MITM Attack Demo — Rogue WiFi Proxy"

    warn "SIMULATING ATTACK: routing emulator traffic through mitmproxy"
    warn "In a real attack, this is done by a rogue WiFi AP."

    adb shell settings put global http_proxy "${HOST_IP}:${MITM_PORT}"
    log "Proxy set → ${HOST_IP}:${MITM_PORT}"
    log "Now browse http:// sites on the emulator."
    log "Watch intercepted traffic at: http://localhost:8082"
    echo ""
    echo "  To restore (simulate VPN defence):  $0 vpn"
    echo "  Watch traffic at:                   http://localhost:8082"
}

# ── vpn (defence) ─────────────────────────────────────────────────────────────
cmd_vpn() {
    adb_check
    section "Defence: VPN Enforcement (removes rogue proxy)"

    adb shell settings delete global http_proxy
    adb shell settings delete global global_http_proxy_host
    adb shell settings delete global global_http_proxy_port
    adb shell settings delete global global_http_proxy_exclusion_list
    log "Proxy cleared — simulating always-on VPN taking effect."
    log "In MDM: Settings → Network → VPN → [gear] → Always-on VPN: ON"
    log "mitmproxy now sees only encrypted traffic."
}

# ── lock ──────────────────────────────────────────────────────────────────────
cmd_lock() {
    adb_check
    section "Remote Lock"
    log "Locking device screen (simulating MDM remote lock command)..."
    adb shell input keyevent 26
    log "Device locked."
}

# ── audit ─────────────────────────────────────────────────────────────────────
cmd_audit() {
    adb_check
    section "App Permission Audit"

    echo -e "\n${GREEN}Apps with LOCATION permission (background):${NC}"
    adb shell appops query-op MONITOR_LOCATION allow 2>/dev/null | sed 's/^/  /' || \
        adb shell pm list packages 2>/dev/null | head -10 | sed 's/^/  /'

    echo -e "\n${GREEN}Apps with CAMERA permission:${NC}"
    adb shell pm list packages 2>/dev/null | while read pkg; do
        PKG=$(echo "$pkg" | cut -d: -f2)
        adb shell dumpsys package "$PKG" 2>/dev/null | grep -q "android.permission.CAMERA" && echo "  $PKG"
    done | head -10

    echo -e "\n${GREEN}Apps with MICROPHONE permission:${NC}"
    adb shell pm list packages 2>/dev/null | while read pkg; do
        PKG=$(echo "$pkg" | cut -d: -f2)
        adb shell dumpsys package "$PKG" 2>/dev/null | grep -q "android.permission.RECORD_AUDIO" && echo "  $PKG"
    done | head -10

    echo ""
    log "Full permissions UI: Settings → Privacy → Permission Manager"
}

# ── wipe ──────────────────────────────────────────────────────────────────────
cmd_wipe() {
    adb_check
    section "Remote Wipe (Factory Reset)"
    warn "This will factory reset the EMULATOR. Continue? [y/N]"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Initiating factory reset..."
        adb shell am broadcast -a android.intent.action.MASTER_CLEAR \
            --receiver-permission android.permission.MASTER_CLEAR 2>/dev/null || \
            adb shell recovery --wipe_data 2>/dev/null || \
            warn "Factory reset requires device admin rights. Use HMDM admin panel instead."
    else
        log "Wipe cancelled."
    fi
}

# ── help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    cat << EOF

Usage: $0 <command>

  enroll    Install HMDM agent + open enrollment
  info      Show device security posture
  mitm      Route traffic through mitmproxy (simple attack demo)
  mitm-mdm  Same attack, pushed via HMDM server REST API (realistic demo)
  vpn       Clear rogue proxy (defence demo)
  lock      Lock device screen immediately
  audit     App permission audit
  wipe      Factory reset emulator (demo use only)

Demo flow:
  1. $0 enroll    →  enroll device in MDM
  2. $0 info      →  show security baseline
  3. $0 mitm-mdm  →  run attack via MDM API (watch http://localhost:8082)
  4. $0 vpn       →  enforce VPN defence
  5. $0 lock      →  demonstrate remote lock
  6. $0 audit     →  show permission audit

EOF
}

case "${1:-help}" in
    enroll)   cmd_enroll    ;;
    info)     cmd_info      ;;
    mitm)     cmd_mitm      ;;
    mitm-mdm) cmd_mitm_mdm  ;;
    vpn)      cmd_vpn       ;;
    lock)     cmd_lock      ;;
    audit)    cmd_audit     ;;
    wipe)     cmd_wipe      ;;
    *)        cmd_help      ;;
esac
