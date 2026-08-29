# Operator notes

Working notes for running this lab — service credentials, platform quirks, and the fixes for every failure hit while building it. Also serves as the `CLAUDE.md` context file if you open this repo in Claude Code.

## What this repo is

A self-contained MDM (Mobile Device Management) presentation demo for an Advanced Hacking course. It runs entirely on a single Mac and simulates real-world MDM policy enforcement, MITM attacks, and mobile device control across Android and iOS.

## Services

All services run via Docker Compose. **Use `docker-compose` (hyphenated), not `docker compose`** — the installed version is a standalone binary:

```
docker-compose up -d        # start everything
docker-compose down         # stop (keeps data)
docker-compose down -v      # stop + wipe all data
docker logs hmdm-server     # debug a service
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Headwind MDM (Android) | http://localhost:8080 | admin / admin123 |
| NanoMDM (iOS) | http://localhost:9000 | — |
| mitmproxy web UI | http://localhost:8082 | password: admin |
| mitmproxy proxy listener | localhost:8081 | — |
| PostgreSQL | internal only | hmdm / hmdm_pass |

**Note:** `setup.sh` prints `admin / hmdm` but the actual working password is `admin123`. The HMDM password hash algorithm is `SHA1(MD5(password).toUpperCase() + "5YdSYHyg2U")`.

## Android emulator

**Note:** The Android demo requires Android Studio / the Android SDK installed locally and the `mdm_demo` AVD created (`./android/avd-setup.sh create`). Without it, the Android half of the demo cannot run.

AVD name: `mdm_demo` — arm64-v8a, API 30

**Killing the emulator** — `adb emu kill` does not work on this setup. Use:

```bash
pkill -9 -f "qemu-system|emulator64|emulator-arm|emulator.*mdm_demo"
```

**Emulator host alias:** The emulator reaches the Mac host via `10.0.2.2`, not `localhost`. All HMDM server URLs stored in the database must use `http://10.0.2.2:8080/...`.

## Android enrollment flow

```bash
# 1. Install agent (APK copied from hmdm-server container)
adb install -r android/hmdm-agent.apk

# 2. Grant Device Owner (required for kiosk/password policies — must be done before first launch)
adb shell dpm set-device-owner com.hmdm.launcher/com.hmdm.launcher.AdminReceiver

# 3. Launch app
adb shell monkey -p com.hmdm.launcher -c android.intent.category.LAUNCHER 1
```

In the HMDM app: Server URL = `http://10.0.2.2:8080`, Device ID = `DEMO001`

## iOS simulator

Simulator name: `MDM-Demo-iPhone`, UUID stored in `.ios_sim_id`. Currently running iOS 17.4.

**IMPORTANT:** All `ios-sim-demo.sh` commands and `xcrun simctl` commands must be run as the logged-in desktop user, not as root. Simulators booted by root are invisible to Simulator.app.

```bash
./ios/ios-sim-demo.sh start          # boot + open Simulator.app
./ios/ios-sim-demo.sh install        # push security-policy.mobileconfig
./ios/ios-sim-demo.sh show-profile   # pretty-print profile contents
./ios/ios-sim-demo.sh grant-revoke   # demo camera permission control
./ios/ios-sim-demo.sh privacy        # open Privacy settings deep link
./ios/ios-sim-demo.sh reset          # erase simulator (remote wipe demo)
./ios/ios-sim-demo.sh nanomdm        # show NanoMDM server status
```

**Profile install:** `xcrun simctl install` doesn't work for `.mobileconfig` files on iOS 17.4. Drag the file into the Simulator window instead, then tap Install in Settings → General → VPN & Device Management.

**Remote wipe:** The simulator must be shut down before erasing. Run `stop` then `reset` — not `reset` alone on a booted device.

**NanoMDM returns HTTP 404 at root** — this is expected. The server only responds on `/mdm` (device check-in) and `/v1/` (API). HTTP 400 on `/mdm` means it's running correctly.

## Demo scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | First-time setup: certs, Docker, AVD, iOS sim, profiles |
| `verify.sh` | Pre-flight check — run before presenting |
| `reset-demo.sh` | Wipe all state and return to clean starting point |
| `android/adb-demo.sh` | Live ADB commands: enroll, info, mitm, vpn, lock, audit, wipe |
| `android/avd-setup.sh` | AVD lifecycle: create, start, stop, status |
| `ios/ios-sim-demo.sh` | iOS simulator control and profile management |

## MITM attack demo flow

```bash
./android/adb-demo.sh mitm   # routes emulator through mitmproxy on 10.0.2.2:8081
# browse any http:// site on emulator, watch http://localhost:8082
./android/adb-demo.sh vpn    # clears proxy (simulates MDM-enforced VPN kicking in)
```

## Database operations

The PostgreSQL container is named `hmdm-db`. Both Headwind MDM and NanoMDM share it (separate databases: `hmdm` and `nanomdm`).

```bash
# Fix APK download URLs after reset (emulator can't use localhost)
docker exec hmdm-db psql -U hmdm -d hmdm \
  -c "UPDATE applicationversions SET url = REPLACE(url, 'http://localhost', 'http://10.0.2.2:8080') WHERE url LIKE 'http://localhost%';"

# Pre-create demo device
docker exec hmdm-db psql -U hmdm -d hmdm \
  -c "INSERT INTO devices (number, configurationid, customerid, lastupdate) VALUES ('DEMO001', 1, 1, 0) ON CONFLICT (number) DO NOTHING;"

# Clear all enrolled devices
docker exec hmdm-db psql -U hmdm -d hmdm -c "DELETE FROM devices;"
```

## Known quirks

- **HMDM MQTT (port 31000)** must be exposed in docker-compose for policy pushes to reach the device in real time.
- **Payment Kiosk configuration** requires `mainappid`, `contentappid`, and `eventreceivingcomponent` (`com.hmdm.launcher/com.hmdm.launcher.AdminReceiver`) all set, or the SyncResponse throws a NullPointerException.
- **HMDM admin UI** won't save a configuration if any app in the list has an empty `url` field. System apps (action=3) need a non-empty placeholder URL to appear in the UI.
- **iOS APNs**: Real remote push (lock/wipe) requires an Apple Developer account and APNs certificate. The simulator demo uses `xcrun simctl` commands as a stand-in.
- **NanoMDM storage**: Must use `pgsql` storage driver — file storage is deprecated in v0.9.0 and crashes if a CA cert is present.
- **NanoMDM CA cert**: The `./certs` bind mount triggers a macOS Docker Desktop "resource deadlock" error. The CA cert is embedded inline in `docker-compose.yml` as a Docker `config` object (`nanomdm_ca`) to work around this. Do not switch it back to a bind mount.
- **nanomdm database**: The `init-db.sh` path in the repo is a directory (not a file), so Postgres never auto-creates the `nanomdm` database. If starting from a fresh volume, create it manually: `docker exec hmdm-db psql -U hmdm -d postgres -c "CREATE DATABASE nanomdm OWNER hmdm;"`
- **verify.sh checks for `scep-server`** but that container is not defined in `docker-compose.yml`. This failure can be ignored — SCEP is only needed for real iOS PKI enrollment (requires Apple Developer account).

## Presentation

`presentation/index.html` — Reveal.js slide deck (15 slides, served directly from the filesystem — no build step needed).

```bash
open presentation/index.html
```

Speaker notes are embedded in each slide (`<aside class="notes">`). Press `S` in Reveal.js to open speaker view.
