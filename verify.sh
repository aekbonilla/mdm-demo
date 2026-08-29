#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  verify.sh — Check that all MDM demo services are healthy before presenting
# ─────────────────────────────────────────────────────────────────────────────
set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $1"; }
fail() { echo -e "  ${RED}✗${NC}  $1"; FAILED=1; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }

FAILED=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "\n${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  MDM Demo — Pre-Flight Check${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}\n"

# ── Docker containers ─────────────────────────────────────────────────────────
echo "Docker containers:"
for name in hmdm-db hmdm-server nanomdm-server scep-server mitmproxy; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        ok "$name is running"
    else
        fail "$name is NOT running  →  docker logs $name"
    fi
done

# ── HTTP endpoints ─────────────────────────────────────────────────────────────
echo ""
echo "HTTP endpoints:"

check_http() {
    local url="$1" label="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then
        ok "$label  →  HTTP $code"
    else
        fail "$label  →  HTTP $code (unreachable?)"
    fi
}

check_http "http://localhost:8080"  "Headwind MDM     http://localhost:8080"
check_http "http://localhost:9000"  "NanoMDM          http://localhost:9000"
check_http "http://localhost:8083"  "SCEP server       http://localhost:8083"
check_http "http://localhost:8082"  "mitmproxy UI      http://localhost:8082"

# ── Certificates ─────────────────────────────────────────────────────────────
echo ""
echo "Certificates:"
for f in certs/ca.crt certs/server.crt certs/server.key; do
    [ -f "$f" ] && ok "$f" || fail "$f missing  →  run setup.sh first"
done

# ── iOS profile ──────────────────────────────────────────────────────────────
echo ""
echo "iOS profiles:"
[ -f ios/profiles/security-policy.mobileconfig ] && \
    ok "ios/profiles/security-policy.mobileconfig" || \
    fail "iOS profile missing  →  run setup.sh"

# ── Android environment ────────────────────────────────────────────────────────
echo ""
echo "Android environment:"
if [ -n "$ANDROID_HOME" ] || [ -d "$HOME/Library/Android/sdk" ]; then
    ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    ok "Android SDK: $ANDROID_HOME"
else
    warn "ANDROID_HOME not set"
fi

if command -v adb &>/dev/null; then
    ok "adb: $(adb --version | head -1)"
else
    warn "adb not in PATH — add Android platform-tools to PATH"
fi

if command -v avdmanager &>/dev/null; then
    if avdmanager list avd 2>/dev/null | grep -q "mdm_demo"; then
        ok "AVD 'mdm_demo' exists"
    else
        warn "AVD 'mdm_demo' not found — run: ./android/avd-setup.sh create"
    fi
else
    warn "avdmanager not in PATH"
fi

ADB_DEVICES=$(adb devices 2>/dev/null | grep -c "emulator" || echo 0)
if [ "$ADB_DEVICES" -gt 0 ]; then
    ok "Android emulator running ($ADB_DEVICES device(s) detected)"
else
    warn "No Android emulator running — start one before the demo"
fi

# ── iOS environment (macOS only) ──────────────────────────────────────────────
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo ""
    echo "iOS environment:"
    if command -v xcrun &>/dev/null; then
        ok "xcrun: $(xcode-select -p)"
        if [ -f .ios_sim_id ]; then
            SIM_ID=$(cat .ios_sim_id)
            SIM_STATE=$(xcrun simctl list devices 2>/dev/null | grep "$SIM_ID" | grep -oE 'Booted|Shutdown' || echo "unknown")
            if [ "$SIM_STATE" = "Booted" ]; then
                ok "iOS Simulator $SIM_ID is Booted"
            else
                warn "iOS Simulator $SIM_ID is $SIM_STATE — run: ./ios/ios-sim-demo.sh start"
            fi
        else
            warn ".ios_sim_id not found — run setup.sh"
        fi
    else
        warn "Xcode not installed"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All checks passed. Ready to present!${NC}"
    echo ""
    echo "Quick launch:"
    echo "  Headwind MDM:   open http://localhost:8080"
    echo "  mitmproxy UI:   open http://localhost:8082"
    echo "  Presentation:   open presentation/index.html"
else
    echo -e "${RED}Some checks failed. Run ./setup.sh to fix.${NC}"
    exit 1
fi
echo ""
