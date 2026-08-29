#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  android/avd-setup.sh — Create, start, and stop the Android demo emulator
#  Usage: ./avd-setup.sh [create|start|stop|status]
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; exit 1; }

AVD_NAME="mdm_demo"
API_LEVEL="30"
ABI="x86_64"
PACKAGE="system-images;android-${API_LEVEL};google_apis;${ABI}"

# Locate Android SDK
for candidate in \
    "$ANDROID_HOME" \
    "$HOME/Library/Android/sdk" \
    "$HOME/Android/Sdk"; do
    if [ -d "$candidate" ]; then
        export ANDROID_HOME="$candidate"
        break
    fi
done

[ -z "$ANDROID_HOME" ] && error "Android SDK not found. Set ANDROID_HOME."

export PATH="\
$ANDROID_HOME/emulator:\
$ANDROID_HOME/cmdline-tools/latest/bin:\
$ANDROID_HOME/platform-tools:\
$PATH"

cmd_create() {
    log "Downloading system image: $PACKAGE"
    yes | sdkmanager "$PACKAGE" "platforms;android-$API_LEVEL" "emulator" "platform-tools" \
        2>/dev/null | grep -v "^$" | tail -3

    log "Creating AVD: $AVD_NAME"
    echo "no" | avdmanager create avd \
        --name "$AVD_NAME" \
        --package "$PACKAGE" \
        --device "pixel_4" \
        --force
    log "AVD '$AVD_NAME' created."
}

cmd_start() {
    if ! avdmanager list avd 2>/dev/null | grep -q "$AVD_NAME"; then
        warn "AVD not found. Creating it first..."
        cmd_create
    fi

    log "Starting emulator '$AVD_NAME' (headless: use -no-window flag for CI)..."
    emulator \
        -avd "$AVD_NAME" \
        -dns-server 8.8.8.8 \
        -no-boot-anim \
        -no-audio &

    log "Waiting for emulator to boot..."
    adb wait-for-device
    # Wait for boot animation to finish
    until adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; do
        sleep 3
        echo -n "."
    done
    echo ""
    log "Emulator ready. Connected devices:"
    adb devices
}

cmd_stop() {
    log "Stopping emulator..."
    adb emu kill 2>/dev/null && log "Emulator stopped." || warn "No emulator running."
}

cmd_status() {
    echo "AVDs available:"
    avdmanager list avd 2>/dev/null || warn "avdmanager not found"
    echo ""
    echo "Running devices:"
    adb devices
}

case "${1:-status}" in
    create) cmd_create ;;
    start)  cmd_start  ;;
    stop)   cmd_stop   ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 [create|start|stop|status]"
        exit 1
        ;;
esac
