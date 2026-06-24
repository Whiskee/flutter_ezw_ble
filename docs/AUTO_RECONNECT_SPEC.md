# Native Auto Reconnect Design

This is the active plugin contract for native BLE auto reconnect and iOS
CoreBluetooth State Preservation / Restoration. Android Companion Device
Manager is intentionally out of scope for the active implementation; older CDM
documents in this repo are archived research notes, not current APIs.

For iOS State Preservation / Restoration details, see
`docs/IOS_STATE_RESTORATION_SPEC.md`. For repository architecture and channel
contracts, see `ARCHITECTURE.md`.

## Goal

`flutter_ezw_ble` provides a native auto reconnect supervisor for devices that have already reached the business `connected` state. Android and iOS own reconnect scheduling, cancellation, backoff, and GATT restoration. Dart callers keep the existing `connectStatusEC` flow and only opt in through `BleConfig`.

This design is intended for `even_connect` integration: `even_connect` declares which device configs support native auto reconnect, listens to the existing connection stream, sends the G2 business authentication command when `connectFinish` arrives, then calls `devicePreConnected(uuid)` only after the authentication callback reports success. For the right leg it then sends the channel switch and time sync commands before finally calling `deviceConnected(uuid)`.

For G2, the scan config must keep `BleScan.matchCount = 2`. G2 is exposed to business code as one whole device only after both BLE endpoints with the same SN have been paired by the native scanner. A single-leg scan hit must not be shown as a connectable G2 item.

## Public Contract

Add these fields to `BleConfig`:

| Field | Default | Meaning |
| --- | --- | --- |
| `autoReconnect` | `false` | Enables native auto reconnect for devices using this config. |
| `autoReconnectMaxAttempts` | `0` | Legacy/backoff compatibility field. Native reconnect no longer stops because this count is reached. |
| `autoReconnectBaseDelayMs` | `1000` | Initial reconnect delay. |
| `autoReconnectMaxDelayMs` | `30000` | Maximum exponential backoff delay. |
| `autoReconnectUseNativePassive` | `true` | Allows platform passive reconnect paths when active reconnect cannot see the device. |

The default behavior remains unchanged. Existing callers must explicitly opt in.

## State Flow

Native auto reconnect reuses the existing connection states:

```text
connected
  -> disconnectFromSys
  -> connecting
  -> searchService
  -> searchChars
  -> connectFinish
  -> connected
```

No new EventChannel is required. Native may emit repeated `connecting` and existing terminal error states (`timeout`, `serviceFail`, `charsFail`, `noDeviceFound`) while it keeps retrying internally.

## Reconnect Task Lifecycle

Each platform keeps one reconnect task per device:

```text
belongConfig
uuid
name
sn or mac
attempt
foreground watchdog timer or job
pending native connection handle owned by the OS
pausedByBluetoothOff
cancelledByUser
```

The task is armed only after the app confirms business success through `deviceConnected(uuid)`. First-connect failures are not auto retried unless the device was previously business-connected.

The task is a long-lived reconnect intent. Native must keep it alive until an
explicit owner cancels it, because timeout/noDeviceFound/service failures only
describe one failed attempt, not the end of the reconnect contract.

Cancel the task only on:

- `disconnectDevice`
- `resetBle`
- `cleanConnectCache`
- `removeBond`
- config removed or `autoReconnect=false`
- plugin release

Pause the task on Bluetooth off. Resume paused tasks when Bluetooth returns to powered on.

## Trigger Rules

Schedule reconnect when all are true:

- The device's `BleConfig.autoReconnect == true`.
- The device has reached business `connected` at least once in this manager lifetime.
- The state is `disconnectFromSys`, `timeout`, `serviceFail`, `charsFail`, or `noDeviceFound`.
- The failure was not caused by user disconnect, reset, remove-bond, or expected OTA transition.
- Bluetooth is currently usable, or the task can be paused until it is usable.

Do not schedule reconnect for:

- `disconnectByUser`
- `emptyUuid`
- `noBleConfigFound`
- `alreadyBound`
- `boundFail`
- `bleError`
- `systemError`
- Devices currently in `upgrade`

## Backoff And Passive Handles

Delay is exponential:

```text
delay = min(autoReconnectMaxDelayMs, autoReconnectBaseDelayMs * 2^(attempt - 1))
```

Native reconnect is a persistent intent after `deviceConnected(uuid)`. Reaching
`autoReconnectMaxAttempts`, `timeout`, `noDeviceFound`, `serviceFail`, or
`charsFail` must not delete the task. Those states only advance the backoff or
refresh a native passive handle. A successful business `connected` resets the
attempt counter.

Android passive refresh is intentionally decoupled from the exponential backoff.
Once the supervisor owns an `autoConnect=true` GATT, the watchdog closes stale
pending handles on a short fixed cadence and schedules the replacement handle
with a short retry delay. This keeps a device that returns after several minutes
from waiting behind a maxed-out `autoReconnectMaxDelayMs` attempt window.

Backoff is not the primary wakeup mechanism on iOS. When a known iOS peripheral supports native passive reconnect, the reconnect attempt should immediately create a CoreBluetooth pending connect and let the OS hold it while the app is backgrounded, suspended, or later restored. App timers are allowed only as foreground/manual-connect watchdogs or Android vendor-stack cleanup; they must not be the thing that waits for an iOS device to return.

## GATT Restoration Gate

Native reconnect is successful only after every configured private service is restored:

1. Discover all services.
2. For every `BlePrivateService`, find the write characteristic.
3. For every `BlePrivateService`, find the read characteristic.
4. Enable notify/CCCD for every read characteristic.
5. Emit `connectFinish` only after all configured services pass.

If any service, characteristic, or notify setup fails, native emits the existing failure state and schedules the next reconnect attempt.

For iOS, the finish gate must require:

```swift
writeCharsDic.count == bleConfig.privateServices.count
readCharsDic.count == bleConfig.privateServices.count
readCharsNotify == bleConfig.privateServices.count
```

This prevents multi-service devices from reaching `connectFinish` after only the first notify succeeds.

## Android Strategy

Android uses the existing active `connect(...)` path first. This preserves:

- Stable device name resolution.
- Scan-before-connect when Bluetooth stack cache is stale.
- System GATT connected detection.
- Scan-then-connect pending queue and self-lock prevention.

When active reconnect cannot see the target and `autoReconnectUseNativePassive == true`, Android may use `BluetoothDevice.connectGatt(..., autoConnect = true, ...)` as a passive reconnect handle. The supervisor must still keep a watchdog; when the watchdog expires, it closes the pending GATT and creates a fresh passive handle without emitting a Dart/UI timeout. This avoids vendor Bluetooth stacks leaving a zombie pending connection forever while the visible app state remains connecting.

The Android watchdog is a zombie-GATT refresh mechanism, not a stop condition or
visible connection failure.
If the device remains away for a long time, the supervisor keeps recreating or
rescheduling the reconnect attempt until the task is explicitly cancelled.
The refresh cadence must stay short and bounded separately from attempt backoff;
attempt count is diagnostic in this path, not the delay source.
The scheduled refresh attempt must clear the fired timer before duplicate
connection guards run; otherwise the supervisor can reject its own refresh while
the device is still visibly `CONNECTING` and `passiveGatt` has already been
closed.

## iOS Strategy

iOS uses CoreBluetooth pending connects before scanning. The important rule is: after a previously business-connected device disconnects unexpectedly, the app must hand a known `CBPeripheral` back to CoreBluetooth immediately. That pending `connect` is the preserved operation that can wake or relaunch the app later.

iOS lookup order:

1. `retrieveConnectedPeripherals(withServices:)`, using configured private services plus ANCS.
2. `retrievePeripherals(withIdentifiers:)`.
3. If a peripheral is known, call `centralManager.connect` immediately with the native reconnect option when available.
4. If no peripheral is known but a stable name exists, scan by name with the existing scan-connect timeout.

iOS 17+ may pass `CBConnectPeripheralOptionEnableAutoReconnect` when available. Lower versions still keep a pending `centralManager.connect` for a known peripheral and rely on CoreBluetooth to complete the connection when the device returns. Apps that need background reconnect must configure `UIBackgroundModes = bluetooth-central` and use CoreBluetooth state restoration.

The iOS plugin must not pass `CBCentralManagerOptionRestoreIdentifierKey` unless
the host app has declared `UIBackgroundModes = bluetooth-central`. Apple raises
an `NSException` for that combination. When the mode is missing, the plugin
falls back to a normal central manager: foreground BLE and pending connects can
still work while State Restoration background relaunch is disabled.

Do not start the short connect timeout while the reconnect is only pending in CoreBluetooth; otherwise the app can cancel the preserved connect before the peripheral returns. Start the normal timeout after `didConnect`, then require service discovery, characteristic discovery, CCCD writes, `connectFinish`, G2 AUTH, and final `deviceConnected`.

CoreBluetooth pending connect is the iOS long-wait mechanism. App timers may
update diagnostics, but must not cancel the pending connect or emit a Dart/UI
timeout just because the peripheral stayed away for minutes or hours.

## even_connect Integration

1. Enable `autoReconnect` on the desired `BleConfig`.
2. For G2, configure `scan.matchCount = 2` and show scan results only after native emits the paired `BleMatchDevice` containing both endpoints.
3. Keep listening to `connectStatusEC`.
4. Stop running a parallel Dart reconnect loop for native-managed configs.
5. On `connectFinish`, send G2 `AUTHENTICATION(0x04)` through `UX_DEVICE_SETTINGS_APP_ID(0x80)` with `AuthMgr.secAuth = true`, the platform-specific `phoneType`, `syncBoth = false`, `timeout = 500ms`, and `maxRetry = 1`.
6. Wait for the `DevCfgDataPackage` callback. Only when `authMgr.secAuth == true`, call `devicePreConnected(uuid)` to enter the bounded auth grace window.
7. For the right leg, send `PIPE_ROLE_CHANGE(0x05)` with `asCmdRole = RIGHT`, then send `TIME_SYNC(0x80)` with the current timestamp and 15-minute timezone unit.
8. Call `deviceConnected(uuid)` in the post-auth `finally` path so native can publish the final `connected` state.
9. On user disconnect, call `disconnectDevice`; native cancels the reconnect task.

## Acceptance Matrix

- User disconnect does not reconnect.
- Device power loss then power restore reconnects to `connectFinish`.
- All private services are writable and notify-capable after reconnect.
- Bluetooth off pauses tasks; Bluetooth on resumes them.
- iOS ANCS/system-connected devices do not fall into scan timeout.
- Android out-of-range devices can recover through passive reconnect when enabled.
- Long out-of-range periods do not stop native reconnect unless user/business explicitly cancels it.
- OTA state is not hijacked by normal auto reconnect.
- Authentication hang after `connectFinish` times out and retries instead of getting stuck.
- G2 scan results are displayed only after both legs are matched by `matchCount = 2`.
- G2 is marked business-connected only after `AUTHENTICATION` returns `authMgr.secAuth == true`; right-leg `PIPE_ROLE_CHANGE` and `TIME_SYNC` run before final `deviceConnected`.
