#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  MDM Demo Setup Script
#  Sets up: Headwind MDM (Android) + NanoMDM (iOS) + mitmproxy + emulators
# ─────────────────────────────────────────────────────────────────────────────
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[-]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; \
           echo -e "${BLUE}  $1${NC}"; \
           echo -e "${BLUE}════════════════════════════════════════${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
check_prereqs() {
    header "Checking Prerequisites"

    # Docker
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log "Docker: $(docker --version)"
    else
        error "Docker not running. Start Docker Desktop and retry."
    fi

    # docker-compose (v1) or docker compose (v2)
    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        log "docker-compose: $(docker-compose --version)"
    elif docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        log "docker compose: $(docker compose version)"
    else
        error "docker-compose not found. Install Docker Desktop (includes Compose)."
    fi
    export COMPOSE_CMD

    # Android SDK
    for candidate in \
        "$HOME/Library/Android/sdk" \
        "$HOME/Android/Sdk" \
        "$ANDROID_HOME"; do
        if [ -d "$candidate" ]; then
            export ANDROID_HOME="$candidate"
            export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
            log "Android SDK: $ANDROID_HOME"
            break
        fi
    done
    [ -z "$ANDROID_HOME" ] && warn "Android SDK not found — install Android Studio first."

    # Xcode (macOS)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if xcode-select -p &>/dev/null 2>&1; then
            log "Xcode CLI: $(xcode-select -p)"
        else
            warn "Xcode CLI tools not installed. Run: xcode-select --install"
        fi
    fi

    # openssl
    command -v openssl &>/dev/null && log "openssl: $(openssl version)" || \
        warn "openssl not found — cert generation will be skipped."
}

# ── 2. TLS certificates for NanoMDM ─────────────────────────────────────────
generate_certs() {
    header "Generating TLS Certificates"
    mkdir -p certs

    if [ -f certs/ca.crt ] && [ -f certs/server.crt ]; then
        log "Certificates already exist — skipping."
        return
    fi

    # CA
    openssl genrsa -out certs/ca.key 4096 2>/dev/null
    openssl req -x509 -new -nodes \
        -key certs/ca.key -sha256 -days 365 \
        -out certs/ca.crt \
        -subj "/C=US/ST=Demo/O=MDM-Demo/CN=MDM-Demo-CA" 2>/dev/null

    # Server cert with SAN
    cat > certs/server.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
subjectAltName=@alt_names
[alt_names]
DNS.1=localhost
IP.1=127.0.0.1
IP.2=10.0.2.2
EOF

    openssl genrsa -out certs/server.key 2048 2>/dev/null
    openssl req -new -key certs/server.key -out certs/server.csr \
        -subj "/C=US/ST=Demo/O=MDM-Demo/CN=localhost" 2>/dev/null
    openssl x509 -req -in certs/server.csr \
        -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
        -out certs/server.crt -days 365 -sha256 \
        -extfile certs/server.ext 2>/dev/null

    log "CA certificate:     certs/ca.crt"
    log "Server certificate: certs/server.crt"
    log "Server key:         certs/server.key"
}

# ── 3. Docker services ───────────────────────────────────────────────────────
start_services() {
    header "Starting Docker Services"
    $COMPOSE_CMD up -d --pull missing

    log "Waiting for services to initialise (30 s)..."
    sleep 30

    declare -A SERVICES=(
        ["hmdm-db"]="PostgreSQL (Headwind)"
        ["hmdm-server"]="Headwind MDM"
        ["nanomdm-server"]="NanoMDM (iOS)"
        ["scep-server"]="SCEP (iOS certs)"
        ["mitmproxy"]="mitmproxy"
    )

    for container in "${!SERVICES[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            log "${SERVICES[$container]}: running"
        else
            warn "${SERVICES[$container]}: not running — check: docker logs $container"
        fi
    done
}

# ── 4. Android AVD ──────────────────────────────────────────────────────────
setup_android_avd() {
    header "Android Emulator (AVD)"

    if ! command -v avdmanager &>/dev/null; then
        warn "avdmanager not in PATH. Create AVD manually in Android Studio:"
        warn "  Tools → Device Manager → + → Pixel 6 → API 30"
        return
    fi

    if avdmanager list avd 2>/dev/null | grep -q "mdm_demo"; then
        log "AVD 'mdm_demo' already exists."
        return
    fi

    log "Downloading Android 11 (API 30) system image..."
    yes | sdkmanager \
        "system-images;android-30;google_apis;x86_64" \
        "platforms;android-30" \
        "emulator" \
        "platform-tools" 2>/dev/null | grep -v "^$" | tail -5 || \
        warn "SDK download had warnings — may still work."

    echo "no" | avdmanager create avd \
        --name "mdm_demo" \
        --package "system-images;android-30;google_apis;x86_64" \
        --device "pixel_4" \
        --force 2>/dev/null && \
        log "AVD 'mdm_demo' created." || \
        warn "AVD creation failed — use Android Studio Device Manager instead."
}

# ── 5. iOS Simulator ─────────────────────────────────────────────────────────
setup_ios_simulator() {
    header "iOS Simulator"

    if [[ "$OSTYPE" != "darwin"* ]]; then
        warn "iOS Simulator is macOS only — skipping."
        return
    fi

    if ! command -v xcrun &>/dev/null; then
        warn "Xcode not installed — skipping iOS simulator setup."
        return
    fi

    # Pick best available iOS runtime
    RUNTIME=$(xcrun simctl list runtimes available 2>/dev/null | \
        grep "iOS" | sort -rV | head -1 | \
        grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+')

    if [ -z "$RUNTIME" ]; then
        warn "No iOS runtime found. Install one via: Xcode → Settings → Platforms"
        return
    fi
    log "Using runtime: $RUNTIME"

    # Reuse or create simulator
    SIM_ID=$(xcrun simctl list devices 2>/dev/null | \
        grep "MDM-Demo-iPhone" | \
        grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | \
        head -1)

    if [ -n "$SIM_ID" ]; then
        log "Simulator already exists: $SIM_ID"
    else
        DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-14"
        SIM_ID=$(xcrun simctl create "MDM-Demo-iPhone" "$DEVICE_TYPE" "$RUNTIME" 2>/dev/null)
        if [ -n "$SIM_ID" ]; then
            log "Simulator created: $SIM_ID"
        else
            warn "Could not create simulator — create one manually in Xcode."
            return
        fi
    fi

    echo "$SIM_ID" > .ios_sim_id
    log "Simulator ID saved to .ios_sim_id"
}

# ── 6. iOS configuration profiles ────────────────────────────────────────────
generate_ios_profiles() {
    header "iOS Configuration Profiles"
    mkdir -p ios/profiles

    # Security policy profile
    cat > ios/profiles/security-policy.mobileconfig << 'MOBILECONFIG'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadDisplayName</key>  <string>MDM Demo — Security Policy</string>
  <key>PayloadIdentifier</key>   <string>com.mdm-demo.policy</string>
  <key>PayloadType</key>         <string>Configuration</string>
  <key>PayloadUUID</key>         <string>D4E5F6A7-B8C9-0123-DEFA-234567890001</string>
  <key>PayloadVersion</key>      <integer>1</integer>
  <key>PayloadContent</key>
  <array>

    <!-- 1. Passcode Policy -->
    <dict>
      <key>PayloadType</key>        <string>com.apple.mobiledevice.passwordpolicy</string>
      <key>PayloadIdentifier</key>  <string>com.mdm-demo.passcode</string>
      <key>PayloadUUID</key>        <string>A1B2C3D4-E5F6-7890-ABCD-EF1234560001</string>
      <key>PayloadVersion</key>     <integer>1</integer>
      <key>PayloadDisplayName</key> <string>Passcode Policy</string>
      <!-- minimum 8-char alphanumeric PIN -->
      <key>minLength</key>          <integer>8</integer>
      <key>requireAlphanumeric</key><true/>
      <!-- lock after 30 s idle -->
      <key>maxInactivity</key>      <integer>30</integer>
      <!-- wipe after 6 failed attempts -->
      <key>maxFailedAttempts</key>  <integer>6</integer>
      <key>forcePIN</key>           <true/>
    </dict>

    <!-- 2. Always-on VPN -->
    <dict>
      <key>PayloadType</key>        <string>com.apple.vpn.managed</string>
      <key>PayloadIdentifier</key>  <string>com.mdm-demo.vpn</string>
      <key>PayloadUUID</key>        <string>B2C3D4E5-F6A7-8901-BCDE-F12345670001</string>
      <key>PayloadVersion</key>     <integer>1</integer>
      <key>PayloadDisplayName</key> <string>Always-On VPN</string>
      <key>UserDefinedName</key>    <string>Corporate VPN</string>
      <key>VPNType</key>            <string>IKEv2</string>
      <key>OnDemandEnabled</key>    <integer>1</integer>
      <key>OnDemandRules</key>
      <array>
        <dict>
          <key>Action</key><string>Connect</string>
        </dict>
      </array>
    </dict>

    <!-- 3. Device Restrictions -->
    <dict>
      <key>PayloadType</key>        <string>com.apple.applicationaccess</string>
      <key>PayloadIdentifier</key>  <string>com.mdm-demo.restrictions</string>
      <key>PayloadUUID</key>        <string>C3D4E5F6-A7B8-9012-CDEF-123456780001</string>
      <key>PayloadVersion</key>     <integer>1</integer>
      <key>PayloadDisplayName</key> <string>Security Restrictions</string>
      <!-- disable camera -->
      <key>allowCamera</key>                    <false/>
      <!-- block app installs from outside MDM -->
      <key>allowInstallApp</key>                <false/>
      <!-- block untrusted TLS certs -->
      <key>allowUntrustedTLSPrompt</key>        <false/>
      <!-- enforce encrypted backups -->
      <key>forceEncryptedBackup</key>           <true/>
      <!-- prevent data leakage between managed/unmanaged apps -->
      <key>allowOpenFromManagedToUnmanaged</key><false/>
      <key>allowOpenFromUnmanagedToManaged</key><false/>
      <!-- block AirDrop -->
      <key>allowAirDrop</key>                   <false/>
      <!-- block screenshot in managed context -->
      <key>allowScreenShot</key>                <false/>
    </dict>

    <!-- 4. Wi-Fi Profile -->
    <dict>
      <key>PayloadType</key>        <string>com.apple.wifi.managed</string>
      <key>PayloadIdentifier</key>  <string>com.mdm-demo.wifi</string>
      <key>PayloadUUID</key>        <string>E5F6A7B8-C9D0-1234-EFAB-234567890001</string>
      <key>PayloadVersion</key>     <integer>1</integer>
      <key>PayloadDisplayName</key> <string>Corporate Wi-Fi</string>
      <key>SSID_STR</key>           <string>MDM-Corp-Demo</string>
      <key>EncryptionType</key>     <string>WPA2</string>
      <key>AutoJoin</key>           <true/>
    </dict>

  </array>
</dict>
</plist>
MOBILECONFIG

    log "Profile written: ios/profiles/security-policy.mobileconfig"

    # Install on simulator if available
    if [ -f .ios_sim_id ]; then
        SIM_ID=$(cat .ios_sim_id)
        xcrun simctl boot "$SIM_ID" 2>/dev/null && sleep 8 || true
        open -a Simulator 2>/dev/null || true
        xcrun simctl install "$SIM_ID" ios/profiles/security-policy.mobileconfig 2>/dev/null && \
            log "Profile installed on simulator $SIM_ID" || \
            warn "Automatic profile install unsupported on this iOS version."
        log "Manual install: Settings → General → VPN & Device Management"
    fi
}

# ── 7. Summary ───────────────────────────────────────────────────────────────
print_summary() {
    header "Setup Complete"
    cat << EOF

${GREEN}ANDROID (Headwind MDM)${NC}
  Admin panel:   http://localhost:8080
  Credentials:   admin / hmdm
  Emulator name: mdm_demo

${GREEN}iOS (NanoMDM)${NC}
  Server:        http://localhost:9000
  SCEP:          http://localhost:8083/scep
  Profile:       ios/profiles/security-policy.mobileconfig

${GREEN}NETWORK ATTACK (mitmproxy)${NC}
  Proxy:         localhost:8081
  Web UI:        http://localhost:8082

${GREEN}NEXT STEPS${NC}
  1. Start Android emulator:  ./android/avd-setup.sh start
  2. Enroll Android device:   ./android/adb-demo.sh enroll
  3. Start iOS simulator:     ./ios/ios-sim-demo.sh start
  4. Run attack demo:         ./android/adb-demo.sh mitm
  5. Open presentation:       open presentation/index.html

${YELLOW}NOTE — iOS APNs${NC}
  Real MDM push commands require an Apple Push Notification certificate
  from an Apple Developer account (\$99/yr). The NanoMDM server and
  configuration profiles are fully functional — only remote push is
  limited to real devices with APNs certs.

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    check_prereqs
    generate_certs
    start_services
    setup_android_avd
    setup_ios_simulator
    generate_ios_profiles
    print_summary
}

main "$@"
