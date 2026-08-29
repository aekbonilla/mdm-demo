#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  reset-demo.sh — Wipe all demo state and return to a clean starting point
# ─────────────────────────────────────────────────────────────────────────────
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
header() { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; \
           echo -e "${BLUE}  $1${NC}"; \
           echo -e "${BLUE}════════════════════════════════════════${NC}"; }

ANDROID_HOME="/Users/austinbonilla/Library/Android/sdk"
ADB="$ANDROID_HOME/platform-tools/adb"

# ── 1. Android emulator ───────────────────────────────────────────────────────
header "Resetting Android Emulator"

EMULATOR="$ANDROID_HOME/emulator/emulator"
AVD_NAME="mdm_demo"

# Kill any running emulator instance
if pkill -9 -f "qemu-system|emulator64|emulator-arm|emulator.*${AVD_NAME}" 2>/dev/null; then
    log "Stopped running emulator."
    sleep 2
fi

# Boot with -wipe-data for a truly clean userdata partition
# (avoids HMDM/device-owner state persisting across resets via snapshots or userdata.img)
log "Starting emulator with wiped userdata (clean state)..."
env HOME="/Users/austinbonilla" \
    ANDROID_AVD_HOME="/Users/austinbonilla/.android/avd" \
    "$EMULATOR" -avd "$AVD_NAME" -dns-server 8.8.8.8 \
    -no-boot-anim -no-audio -wipe-data &

log "Waiting for emulator to boot..."
$ADB wait-for-device 2>/dev/null
sleep 15
until [ "$($ADB shell getprop sys.boot_completed 2>/dev/null)" = "1" ]; do
    sleep 3
done
log "Android emulator booted clean."

# ── 2. HMDM database ──────────────────────────────────────────────────────────
header "Resetting HMDM Database"

if docker ps --format '{{.Names}}' | grep -q "hmdm-db"; then
    log "Removing all enrolled devices..."
    docker exec hmdm-db psql -U hmdm -d hmdm \
        -c "DELETE FROM devices;" 2>/dev/null
    log "Devices cleared."

    log "Fixing APK download URLs for emulator..."
    docker exec hmdm-db psql -U hmdm -d hmdm \
        -c "UPDATE applicationversions SET url = REPLACE(url, 'http://localhost', 'http://10.0.2.2:8080') WHERE url LIKE 'http://localhost%';" 2>/dev/null
    log "APK URLs fixed."

    log "Ensuring HMDM agent APK is available for QR code generation..."
    # The HMDM server needs the APK locally to generate QR codes (to compute its hash)
    if ! docker exec hmdm-server test -f /usr/local/tomcat/work/files/hmdm-6.14-os.apk 2>/dev/null; then
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        if [ -f "$SCRIPT_DIR/android/hmdm-agent.apk" ]; then
            docker cp "$SCRIPT_DIR/android/hmdm-agent.apk" hmdm-server:/usr/local/tomcat/work/files/hmdm-6.14-os.apk 2>/dev/null
            log "APK copied to HMDM server."
        else
            warn "android/hmdm-agent.apk not found — QR code generation may fail."
        fi
    else
        log "APK already present."
    fi

    log "Ensuring HMDM base.url includes port (required for QR code)..."
    docker exec hmdm-server sed -i \
        's|value="http://10\.0\.2\.2"|value="http://10.0.2.2:8080"|' \
        /usr/local/tomcat/conf/Catalina/localhost/ROOT.xml 2>/dev/null || true

    log "Resetting mitmproxy..."
    docker restart mitmproxy >/dev/null 2>&1
    log "mitmproxy restarted (traffic log cleared)."
else
    warn "hmdm-db not running — skipping database reset."
fi

# ── 3. iOS simulator ──────────────────────────────────────────────────────────
header "Resetting iOS Simulator"

SIM_ID=$(xcrun simctl list devices 2>/dev/null | \
    grep "MDM-Demo-iPhone" | \
    grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | \
    head -1)

if [ -n "$SIM_ID" ]; then
    log "Shutting down simulator..."
    xcrun simctl shutdown "$SIM_ID" 2>/dev/null || true
    sleep 2
    log "Erasing simulator content..."
    xcrun simctl erase "$SIM_ID" 2>/dev/null && log "iOS simulator erased." || warn "Erase failed."
    log "Booting clean simulator..."
    xcrun simctl boot "$SIM_ID" 2>/dev/null
    open -a Simulator 2>/dev/null
    log "iOS simulator reset and booting."
else
    warn "MDM-Demo-iPhone simulator not found — skipping."
fi

# ── 4. Re-create demo device in HMDM ─────────────────────────────────────────
header "Pre-creating Demo Device"

if docker ps --format '{{.Names}}' | grep -q "hmdm-db"; then
    docker exec hmdm-db psql -U hmdm -d hmdm \
        -c "INSERT INTO devices (number, configurationid, customerid, lastupdate) VALUES ('DEMO001', 1, 1, 0) ON CONFLICT (number) DO NOTHING;" 2>/dev/null
    log "Device DEMO001 ready for enrollment."
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
header "Ready for Presentation"
cat << EOF

${GREEN}ANDROID${NC}
  Emulator wiped and booted clean — no HMDM installed
  Proxy cleared — no MITM active
  Server URL for enrollment:  http://10.0.2.2:8080
  Device ID for enrollment:   DEMO001
  Enroll:  adb install -r android/hmdm-agent.apk
           adb shell dpm set-device-owner com.hmdm.launcher/com.hmdm.launcher.AdminReceiver

${GREEN}iOS${NC}
  Simulator erased and booting fresh
  Profile to install: ios/profiles/security-policy.mobileconfig

${GREEN}SERVICES${NC}
  Headwind MDM:   http://localhost:8080  (admin / admin123)
  mitmproxy UI:   http://localhost:8082  (admin)
  NanoMDM:        http://localhost:9000

EOF
