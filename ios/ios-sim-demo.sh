#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ios/ios-sim-demo.sh — iOS Simulator demo commands
#
#  Commands:
#    start        Boot the MDM-Demo-iPhone simulator
#    open         Open the Simulator.app
#    install      Install the security profile on the simulator
#    show-profile Show profile content (formatted)
#    info         Print device info
#    privacy      Open Privacy settings pane
#    reset        Erase all content (simulate remote wipe)
#    stop         Shutdown the simulator
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "iOS Simulator is macOS only."
    exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[-]${NC} $1"; exit 1; }
section(){ echo -e "\n${BLUE}── $1 ────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROFILE="$SCRIPT_DIR/profiles/security-policy.mobileconfig"
SIM_ID_FILE="$PROJECT_DIR/.ios_sim_id"

get_sim_id() {
    if [ -f "$SIM_ID_FILE" ]; then
        cat "$SIM_ID_FILE"
    else
        # Try to find by name
        xcrun simctl list devices 2>/dev/null | \
            grep "MDM-Demo-iPhone" | \
            grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | \
            head -1
    fi
}

require_sim() {
    SIM_ID=$(get_sim_id)
    [ -z "$SIM_ID" ] && error "Simulator not set up. Run: ../setup.sh"
    echo "$SIM_ID"
}

cmd_start() {
    SIM_ID=$(require_sim)
    section "Booting iOS Simulator"

    STATE=$(xcrun simctl list devices 2>/dev/null | grep "$SIM_ID" | grep -oE 'Booted|Shutdown' || echo "unknown")
    if [ "$STATE" = "Booted" ]; then
        log "Simulator already running: $SIM_ID"
    else
        log "Booting simulator: $SIM_ID"
        xcrun simctl boot "$SIM_ID"
        log "Boot command sent."
    fi

    log "Opening Simulator.app..."
    open -a Simulator
    log "Simulator ready."
}

cmd_open() {
    open -a Simulator
    log "Simulator.app opened."
}

cmd_install() {
    SIM_ID=$(require_sim)
    section "Installing Security Profile"

    [ ! -f "$PROFILE" ] && error "Profile not found: $PROFILE  →  run ../setup.sh"

    STATE=$(xcrun simctl list devices 2>/dev/null | grep "$SIM_ID" | grep -oE 'Booted' || echo "")
    [ -z "$STATE" ] && { log "Booting simulator first..."; cmd_start; sleep 5; }

    # Serve the profile via HTTP so Safari can download and trigger the install flow
    PORT=8765
    PROFILE_DIR="$(dirname "$PROFILE")"
    PROFILE_FILE="$(basename "$PROFILE")"

    log "Serving profile via HTTP on port $PORT..."
    python3 -m http.server "$PORT" --directory "$PROFILE_DIR" \
        --bind 127.0.0.1 >/dev/null 2>&1 &
    HTTP_PID=$!
    sleep 1

    log "Opening profile in simulator Safari..."
    xcrun simctl openurl "$SIM_ID" "http://127.0.0.1:$PORT/$PROFILE_FILE"
    sleep 3
    kill $HTTP_PID 2>/dev/null

    echo ""
    log "Profile downloaded — follow these steps in the Simulator:"
    log "  1. Tap 'Allow' in the Safari download prompt"
    log "  2. Open Settings → General → VPN & Device Management"
    log "  3. Tap 'MDM Demo — Security Policy' → Install → enter passcode if prompted"
    echo ""
    log "After install: run './ios/ios-sim-demo.sh show-restrictions' to verify"
}

cmd_show_profile() {
    section "iOS Security Profile Content"

    [ ! -f "$PROFILE" ] && error "Profile not found: $PROFILE"

    # Pretty print the XML
    if command -v python3 &>/dev/null; then
        python3 - << PYEOF
import plistlib, json, sys

with open("$PROFILE", "rb") as f:
    data = plistlib.load(f)

print("Profile:", data.get("PayloadDisplayName"))
print("ID:     ", data.get("PayloadIdentifier"))
print()
print("Payloads:")
for p in data.get("PayloadContent", []):
    ptype = p.get("PayloadType", "")
    pname = p.get("PayloadDisplayName", "")
    print(f"  [{ptype}]  {pname}")
    keys = {k: v for k, v in p.items() if not k.startswith("Payload")}
    for k, v in keys.items():
        print(f"    {k}: {v}")
    print()
PYEOF
    else
        cat "$PROFILE"
    fi
}

cmd_info() {
    SIM_ID=$(require_sim)
    section "iOS Simulator Device Info"

    echo ""
    xcrun simctl list devices 2>/dev/null | grep "$SIM_ID"
    echo ""

    log "Device ID: $SIM_ID"
    log "Runtime: $(xcrun simctl list devices -j 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); \
        [print(r,v) for r,devs in d.get('devices',{}).items() \
        for v in devs if v.get('udid')=='$SIM_ID']" 2>/dev/null || echo "see above")"

    echo ""
    log "Installed apps:"
    xcrun simctl listapps "$SIM_ID" 2>/dev/null | python3 -c \
        "import plistlib,sys
data = plistlib.loads(sys.stdin.buffer.read())
for bundle, info in data.items():
    print(f'  {bundle:50s}  {info.get(\"CFBundleDisplayName\",\"\")}')" 2>/dev/null | head -20 || \
        warn "App list unavailable."
}

cmd_privacy() {
    SIM_ID=$(require_sim)
    section "Opening Privacy & Security Settings"

    # Try several URL schemes — iOS 17 simulator supports App-Prefs on device but
    # prefs: scheme is the simulator-compatible variant
    if xcrun simctl openurl "$SIM_ID" "prefs:root=PRIVACY" 2>/dev/null; then
        log "Opened Privacy & Security settings."
    elif xcrun simctl openurl "$SIM_ID" "prefs:root=Privacy" 2>/dev/null; then
        log "Opened Privacy settings."
    else
        log "Opening Settings app..."
        xcrun simctl openurl "$SIM_ID" "prefs:root" 2>/dev/null
        warn "Navigate manually: Settings → Privacy & Security → Camera"
        warn "After MDM profile install: Camera row shows 'Not Allowed' for all apps"
    fi
}

cmd_passcode() {
    SIM_ID=$(require_sim)
    section "Face ID & Passcode Settings"

    log "Opening Face ID & Passcode settings..."
    if ! xcrun simctl openurl "$SIM_ID" "prefs:root=TOUCHID_PASSCODE" 2>/dev/null; then
        xcrun simctl openurl "$SIM_ID" "prefs:root=General" 2>/dev/null
        warn "Navigate manually: Settings → Face ID & Passcode"
    fi

    echo ""
    log "What to show your audience:"
    log "  BEFORE profile install: passcode is optional, any length accepted"
    log "  AFTER  profile install: iOS enforces min 8-char alphanumeric PIN"
    log "  (On a supervised device, MDM blocks access until passcode meets policy)"
}

cmd_show_restrictions() {
    SIM_ID=$(require_sim)
    section "Verifying Active MDM Restrictions"

    # Check if profile is installed by looking for a managed profile container
    PROFILE_INSTALLED=$(xcrun simctl spawn "$SIM_ID" \
        profiles list 2>/dev/null | grep -i "MDM Demo" || echo "")

    if [ -n "$PROFILE_INSTALLED" ]; then
        log "Profile detected: $PROFILE_INSTALLED"
    else
        warn "Profile may not be installed yet — run './ios-sim-demo.sh install' first"
    fi

    echo ""
    log "Demonstrating camera restriction via xcrun simctl privacy:"
    log "  Attempting to grant camera to Safari (represents over-privileged app)..."
    RESULT=$(xcrun simctl privacy "$SIM_ID" grant camera com.apple.mobilesafari 2>&1)
    if echo "$RESULT" | grep -qi "denied\|restrict\|not allowed\|error"; then
        log "  BLOCKED — MDM policy is enforcing camera restriction!"
        echo "  Output: $RESULT"
    else
        log "  Granted (profile not yet installed or camera not restricted)"
        sleep 1
        xcrun simctl privacy "$SIM_ID" revoke camera com.apple.mobilesafari 2>/dev/null
        log "  Revoked."
    fi

    echo ""
    log "Opening Privacy & Security → Camera to show restriction visually..."
    xcrun simctl openurl "$SIM_ID" "prefs:root=PRIVACY" 2>/dev/null || \
        xcrun simctl openurl "$SIM_ID" "prefs:root=Privacy" 2>/dev/null || \
        xcrun simctl openurl "$SIM_ID" "prefs:root" 2>/dev/null
    log "  Navigate to: Camera — restricted apps show 'Not Allowed'"
}

cmd_grant_revoke() {
    SIM_ID=$(require_sim)
    section "Permission Grant/Revoke Demo"

    log "Step 1 — Grant camera to Safari (simulating an over-permissioned app)..."
    xcrun simctl privacy "$SIM_ID" grant camera com.apple.mobilesafari 2>/dev/null && \
        log "  Camera granted to com.apple.mobilesafari"

    log "  Opening Privacy settings to show grant is visible..."
    xcrun simctl openurl "$SIM_ID" "prefs:root=PRIVACY" 2>/dev/null || \
        xcrun simctl openurl "$SIM_ID" "prefs:root=Privacy" 2>/dev/null || \
        xcrun simctl openurl "$SIM_ID" "prefs:root" 2>/dev/null
    log "  In Simulator: navigate to Camera — Safari shows 'Allow'"
    echo ""
    read -r -p "  Press Enter when ready to simulate MDM revocation..."

    log "Step 2 — MDM revokes camera from Safari (policy enforcement)..."
    xcrun simctl privacy "$SIM_ID" revoke camera com.apple.mobilesafari 2>/dev/null && \
        log "  Camera revoked from com.apple.mobilesafari"
    log "  Check Privacy → Camera in Simulator — Safari is now 'Off'"

    echo ""
    log "Step 3 — Reset all permissions to clean state for next demo..."
    xcrun simctl privacy "$SIM_ID" reset all 2>/dev/null && \
        log "  All permissions reset."
}

cmd_reset() {
    SIM_ID=$(require_sim)
    section "Remote Wipe (Erase All Content)"

    warn "This will ERASE all content on simulator $SIM_ID"
    warn "Continue? [y/N]"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Erasing simulator (simulating MDM remote wipe)..."
        xcrun simctl erase "$SIM_ID" && log "Simulator erased." || error "Erase failed."
    else
        log "Wipe cancelled."
    fi
}

cmd_stop() {
    SIM_ID=$(require_sim)
    section "Shutting Down Simulator"
    xcrun simctl shutdown "$SIM_ID" && log "Simulator shut down." || warn "Shutdown failed."
}

cmd_nanomdm_status() {
    section "NanoMDM Server Status"
    log "Checking NanoMDM API (localhost:9000)..."

    # Ping the NanoMDM server
    RESP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/mdm 2>/dev/null)
    echo "  /mdm endpoint: HTTP $RESP"

    # List enrolled devices
    log "Enrolled devices:"
    curl -s -u nanomdm:nanomdm "http://localhost:9000/v1/id" 2>/dev/null | python3 -m json.tool 2>/dev/null || \
        echo "  (none enrolled — requires APNs cert for full push)"

    echo ""
    warn "iOS MDM Note:"
    warn "  Full remote push (lock/wipe/profile push) requires:"
    warn "  1. Apple Developer account (\$99/yr)"
    warn "  2. APNs push certificate from Apple"
    warn "  3. HTTPS (not HTTP) server"
    warn ""
    warn "  What works NOW in simulation:"
    warn "  ✓ MDM server + API running"
    warn "  ✓ Enrollment profile generated"
    warn "  ✓ Profile installation on simulator"
    warn "  ✓ Policy content demonstration"
    warn "  ✓ xcrun simctl privacy control (grant/revoke)"
    warn "  ✓ Simulator erase (remote wipe equivalent)"
}

cmd_help() {
    cat << EOF

Usage: $0 <command>

  start              Boot MDM-Demo-iPhone simulator + open Simulator.app
  open               Open Simulator.app (if already booted)
  install            Serve + install security profile via Safari
  show-profile       Display profile contents in readable format
  show-restrictions  Verify active MDM restrictions after install
  info               Show simulator device info + installed apps
  privacy            Open Privacy & Security settings in simulator
  passcode           Open Face ID & Passcode settings (show policy enforcement)
  grant-revoke       Demo: grant then revoke camera permission (interactive)
  reset              Erase all content (simulate remote wipe)
  stop               Shutdown the simulator
  nanomdm            Show NanoMDM server status + enrolled devices

Demo flow:
  1. $0 start              →  boot simulator
  2. $0 install            →  push MDM profile (Safari install flow)
  3. $0 show-profile       →  explain policy contents
  4. $0 passcode           →  show passcode policy enforcement
  5. $0 grant-revoke       →  demo camera permission control
  6. $0 show-restrictions  →  verify camera block is active
  7. $0 nanomdm            →  explain server architecture
  8. $0 reset              →  demonstrate remote wipe

EOF
}

case "${1:-help}" in
    start)             cmd_start            ;;
    open)              cmd_open             ;;
    install)           cmd_install          ;;
    show-profile)      cmd_show_profile     ;;
    show-restrictions) cmd_show_restrictions;;
    info)              cmd_info             ;;
    privacy)           cmd_privacy          ;;
    passcode)          cmd_passcode         ;;
    grant-revoke)      cmd_grant_revoke     ;;
    reset)             cmd_reset            ;;
    stop)              cmd_stop             ;;
    nanomdm)           cmd_nanomdm_status   ;;
    *)                 cmd_help             ;;
esac
