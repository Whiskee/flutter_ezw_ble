#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-com.fzfstudio.flutterEzwBleExample}"
SIM_DEVICE="${SIM_DEVICE:-booted}"
DEVICE_ID="${DEVICE_ID:-00008130-00021C882E30001C}"
PID="${PID:-}"
PROCESS_HINT="${PROCESS_HINT:-Runner}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/.tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/ios_state_restoration_$(date +%Y%m%d_%H%M%S).log}"

MATCH_RE='stateRestoration|willRestoreState|pending-after-initConfigs|restore peripheral|connectStatus|BleChannel::connectDevice|G2Demo|didConnect|didDisconnectPeripheral|didFailToConnect|CBConnectPeripheralOptionEnableAutoReconnect'
SIM_LOG_PREDICATE='eventMessage CONTAINS[c] "stateRestoration" OR eventMessage CONTAINS[c] "willRestoreState" OR eventMessage CONTAINS[c] "pending-after-initConfigs" OR eventMessage CONTAINS[c] "restore peripheral" OR eventMessage CONTAINS[c] "connectStatus" OR eventMessage CONTAINS[c] "BleChannel::connectDevice" OR eventMessage CONTAINS[c] "G2Demo" OR eventMessage CONTAINS[c] "didConnect" OR eventMessage CONTAINS[c] "didDisconnectPeripheral" OR eventMessage CONTAINS[c] "didFailToConnect"'

usage() {
  cat <<USAGE
iOS CoreBluetooth State Restoration probe

Usage:
  $(basename "$0") suspend
  $(basename "$0") kill
  $(basename "$0") resume
  $(basename "$0") status
  $(basename "$0") check
  $(basename "$0") sim-observe
  $(basename "$0") sim-terminate
  $(basename "$0") device-observe
  $(basename "$0") device-pids
  $(basename "$0") device-terminate
  $(basename "$0") device-memory-warning

Environment:
  BUNDLE_ID       App bundle id. Default: $BUNDLE_ID
  SIM_DEVICE      Simulator id/name. Default: $SIM_DEVICE
  DEVICE_ID       Physical device id/name/UDID. Default: $DEVICE_ID
  PID             Optional physical-device process pid. Default: auto-detect by BUNDLE_ID.
  PROCESS_HINT    Text used by device-pids grep. Default: $PROCESS_HINT
  WAIT_SECONDS    Log observation window. Default: $WAIT_SECONDS
  LOG_FILE        Output log path. Default: $LOG_FILE

Important:
  suspend keeps the process alive and tests whether a BLE event wakes an
  existing background/suspended app. It should not produce willRestoreState.
  devicectl suspend is a developer-tool freeze. It is not the same as normal
  iOS background suspension, and CoreBluetooth is not expected to thaw it.
  kill terminates the process and tests CoreBluetooth restoration/relaunch.
  sim-terminate and device-terminate are negative/control tests. A user kill,
  Xcode Stop, simctl terminate, or devicectl --kill may prevent restoration.
  Do not use iPhone Bluetooth off/on as the positive "device returns" signal.
  When Bluetooth is powered off, CoreBluetooth cannot keep a pending connect;
  the app must run again after Bluetooth is powered on to create a new pending
  connect. For a positive test, keep iPhone Bluetooth on and make the G2 leave
  by powering off / moving away / shielding the glasses.
  A real relaunch test requires a physical device, bluetooth-central enabled,
  an active/pending CoreBluetooth operation, app backgrounded, and iOS relaunching
  the app due to a BLE event. Look for:
    stateRestoration: willRestoreState
    stateRestoration: restore peripheral
    connectStatus ... searchService / connectFinish

Recommended:
  1. Connect G2 and background the app.
  2. Keep iPhone Bluetooth on, then power off / move away the G2.
  3. Wait for native logs showing a reconnect task and pending connect.
  4. Let iOS background/suspend naturally, or use suspend only as a negative
     developer-freeze check.
  5. Bring the G2 back and watch Console.app for connectStatus/G2Demo logs.
  6. Relaunch/reconnect, then run: $(basename "$0") kill as a negative/control
     check. A positive system-relaunch test should be caused by iOS memory
     pressure/system eviction, not a user/developer kill.
USAGE
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

ensure_log_dir() {
  mkdir -p "$LOG_DIR"
}

print_result_hint() {
  echo
  echo "Log saved to: $LOG_FILE"
  echo "Restoration markers:"
  if grep -E "$MATCH_RE" "$LOG_FILE" >/dev/null 2>&1; then
    grep -En "$MATCH_RE" "$LOG_FILE" | tail -n 80
  else
    echo "  No restoration markers captured in this window."
  fi
  echo
  echo "Positive relaunch evidence must include 'stateRestoration: willRestoreState'."
}

check_static_wiring() {
  local failed=0

  echo "Checking iOS State Restoration wiring..."

  if grep -q 'CBCentralManagerOptionRestoreIdentifierKey' "$ROOT_DIR/ios/Classes/ble/BleManager.swift"; then
    echo "PASS central manager uses CBCentralManagerOptionRestoreIdentifierKey"
  else
    echo "FAIL missing CBCentralManagerOptionRestoreIdentifierKey"
    failed=1
  fi

  if grep -q 'willRestoreState' "$ROOT_DIR/ios/Classes/ble/BleManager.swift"; then
    echo "PASS centralManager(_:willRestoreState:) is implemented"
  else
    echo "FAIL missing centralManager(_:willRestoreState:)"
    failed=1
  fi

  if grep -q 'escrowStateRestorationPeripheral' "$ROOT_DIR/ios/Classes/ble/BleManager.swift"; then
    echo "PASS restored peripherals are routed into pre-claim escrow"
  else
    echo "FAIL missing State Restoration escrow flow"
    failed=1
  fi

  if grep -q 'bluetooth-central' "$ROOT_DIR/example/ios/Runner/Info.plist"; then
    echo "PASS example enables UIBackgroundModes bluetooth-central"
  else
    echo "FAIL example missing UIBackgroundModes bluetooth-central"
    failed=1
  fi

  if grep -q 'pendingBleEvents' "$ROOT_DIR/ios/Classes/ble/BleChannel.swift"; then
    echo "PASS iOS EventChannel buffers events before Flutter listeners attach"
  else
    echo "FAIL iOS EventChannel does not buffer early restoration events"
    failed=1
  fi

  exit "$failed"
}

sim_observe() {
  need xcrun
  ensure_log_dir

  echo "Launching simulator app: $BUNDLE_ID on $SIM_DEVICE"
  xcrun simctl launch "$SIM_DEVICE" "$BUNDLE_ID" >/dev/null || true
  echo
  echo "Connect the G2 in the app, then background the app."
  echo "Press Return to start a ${WAIT_SECONDS}s filtered simulator log capture."
  read -r _

  xcrun simctl spawn "$SIM_DEVICE" log stream \
    --style compact \
    --level debug \
    --timeout "${WAIT_SECONDS}s" \
    --predicate "$SIM_LOG_PREDICATE" | tee "$LOG_FILE"

  print_result_hint
}

sim_terminate() {
  need xcrun
  ensure_log_dir

  echo "Starting filtered simulator log capture in background..."
  xcrun simctl spawn "$SIM_DEVICE" log stream \
    --style compact \
    --level debug \
    --predicate "$SIM_LOG_PREDICATE" >"$LOG_FILE" 2>&1 &
  local log_pid=$!
  trap 'kill "$log_pid" >/dev/null 2>&1 || true' EXIT

  xcrun simctl launch "$SIM_DEVICE" "$BUNDLE_ID" >/dev/null || true
  echo
  echo "Connect the G2 in the app. Press Return to run: simctl terminate $SIM_DEVICE $BUNDLE_ID"
  read -r _

  xcrun simctl terminate "$SIM_DEVICE" "$BUNDLE_ID"
  echo "Waiting ${WAIT_SECONDS}s for any attempted restoration/relaunch logs..."
  sleep "$WAIT_SECONDS"
  kill "$log_pid" >/dev/null 2>&1 || true
  trap - EXIT

  print_result_hint
}

device_observe() {
  ensure_log_dir

  if command -v idevicesyslog >/dev/null 2>&1; then
    echo "Streaming physical-device syslog with idevicesyslog. Stop with Ctrl-C."
    if [[ -n "$DEVICE_ID" ]]; then
      idevicesyslog -u "$DEVICE_ID" | grep -E "$MATCH_RE" | tee "$LOG_FILE"
    else
      idevicesyslog | grep -E "$MATCH_RE" | tee "$LOG_FILE"
    fi
    return
  fi

  cat <<MSG
idevicesyslog is not installed, so this script cannot stream physical-device
logs automatically.

Use Console.app instead:
  1. Select the connected iPhone.
  2. Filter by: stateRestoration OR willRestoreState OR G2Demo OR BleChannel.
  3. Launch the app, connect G2, background the app, then wait for a BLE event.
  4. Positive relaunch evidence is: stateRestoration: willRestoreState.

You can install libimobiledevice if you want this script to stream logs:
  brew install libimobiledevice
MSG
}

device_pids() {
  need xcrun

  local app_path
  local target_pid

  app_path="$(find_device_app_path_or_exit)"
  target_pid="$(find_device_pid "$app_path")"

  echo "Target app status"
  echo "Device: $DEVICE_ID"
  echo "Bundle: $BUNDLE_ID"
  echo "Path:   $app_path"
  if [[ -n "$target_pid" ]]; then
    echo "PID:    $target_pid"
  else
    echo "PID:    not running"
  fi
}

device_processes() {
  need xcrun

  echo "All matching Runner/flutter_ezw processes on $DEVICE_ID"
  xcrun devicectl device info processes \
    --device "$DEVICE_ID" \
    --columns '*' \
    --hide-headers | grep -Ei "$PROCESS_HINT|$BUNDLE_ID|flutter_ezw" || true
}

find_device_app_path() {
  need xcrun
  xcrun devicectl device info apps \
    --device "$DEVICE_ID" \
    --columns '*' |
    awk -v bundle="$BUNDLE_ID" '
      index($0, bundle) > 0 {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^\/private\/var\/containers\/Bundle\/Application\//) {
            print $i
            exit
          }
        }
      }
    '
}

find_device_pid() {
  need xcrun
  local app_path="$1"
  local app_name
  local exec_name
  local executable_path

  app_name="$(basename "$app_path")"
  exec_name="${app_name%.app}"
  executable_path="$app_path/$exec_name"

  xcrun devicectl device info processes \
    --device "$DEVICE_ID" \
    --columns '*' \
    --hide-headers |
    awk -v executable_path="$executable_path" '
      index($0, executable_path) > 0 {
        print $1
        exit
      }
    '
}

find_device_app_path_or_exit() {
  local app_path
  app_path="$(find_device_app_path)"
  if [[ -z "$app_path" ]]; then
    echo "Cannot find installed app for bundle id: $BUNDLE_ID on $DEVICE_ID" >&2
    exit 1
  fi
  echo "$app_path"
}

find_device_pid_or_exit() {
  local app_path="$1"
  local target_pid="$PID"

  if [[ -z "$target_pid" ]]; then
    target_pid="$(find_device_pid "$app_path")"
  fi

  if [[ -z "$target_pid" ]]; then
    echo "App is installed but no running process was found." >&2
    echo "Bundle: $BUNDLE_ID" >&2
    echo "Path:   $app_path" >&2
    echo "Launch/connect/background the app first, then run this script again." >&2
    exit 1
  fi

  echo "$target_pid"
}

print_device_target() {
  local mode="$1"
  local app_path="$2"
  local target_pid="$3"

  echo "$mode"
  echo "Device: $DEVICE_ID"
  echo "Bundle: $BUNDLE_ID"
  echo "Path:   $app_path"
  echo "PID:    $target_pid"
}

device_suspend() {
  need xcrun

  local app_path
  local target_pid

  app_path="$(find_device_app_path_or_exit)"
  target_pid="$(find_device_pid_or_exit "$app_path")"

  print_device_target "Suspending physical-device process" "$app_path" "$target_pid"
  xcrun devicectl device process suspend --device "$DEVICE_ID" --pid "$target_pid"
  echo
  echo "Now trigger a BLE event. This mode tests waking the existing process, not relaunch."
  echo "Expected Console markers: G2Demo/connectStatus/didConnect. willRestoreState is not expected."
  echo "Note: devicectl suspend is a developer freeze; CoreBluetooth may not thaw it."
  echo "Do not turn iPhone Bluetooth off for this positive test. Keep Bluetooth on and make the G2 leave/return."
}

device_resume() {
  need xcrun

  local app_path
  local target_pid

  app_path="$(find_device_app_path_or_exit)"
  target_pid="$(find_device_pid_or_exit "$app_path")"

  print_device_target "Resuming physical-device process" "$app_path" "$target_pid"
  xcrun devicectl device process resume --device "$DEVICE_ID" --pid "$target_pid"
}

device_terminate() {
  need xcrun

  local app_path
  local target_pid

  app_path="$(find_device_app_path_or_exit)"
  target_pid="$(find_device_pid_or_exit "$app_path")"

  print_device_target "Running physical-device SIGKILL restoration/control test" "$app_path" "$target_pid"
  xcrun devicectl device process terminate --device "$DEVICE_ID" --pid "$target_pid" --kill
  echo
  echo "Now trigger a BLE event. This mode tests process relaunch/restoration."
  echo "Expected Console marker if restoration works: stateRestoration: willRestoreState."
}

device_memory_warning() {
  need xcrun

  local app_path
  local target_pid

  app_path="$(find_device_app_path_or_exit)"
  target_pid="$(find_device_pid_or_exit "$app_path")"

  print_device_target "Sending memory warning to physical-device process" "$app_path" "$target_pid"
  xcrun devicectl device process sendMemoryWarning --device "$DEVICE_ID" --pid "$target_pid"
}

case "${1:-}" in
  check)
    check_static_wiring
    ;;
  suspend)
    device_suspend
    ;;
  kill)
    device_terminate
    ;;
  resume)
    device_resume
    ;;
  status)
    device_pids
    ;;
  sim-observe)
    sim_observe
    ;;
  sim-terminate)
    sim_terminate
    ;;
  device-observe)
    device_observe
    ;;
  device-pids)
    device_pids
    ;;
  device-processes)
    device_processes
    ;;
  device-terminate)
    device_terminate
    ;;
  device-memory-warning)
    device_memory_warning
    ;;
  "")
    usage
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
