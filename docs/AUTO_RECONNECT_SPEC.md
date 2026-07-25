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
| `autoReconnectUseNativePassive` | `true` | Allows platform passive reconnect paths when active reconnect cannot see the device. |

`autoReconnectUseNativePassive` is now a legacy compatibility field. Reconnect
activation always uses the platform-native pending/direct path and never falls
back to scan-first because this flag is false.

Public methods:

- `armAutoReconnectTargets(devices)` records long-lived owners only.
- `activateAutoReconnectTargets(devices, source)` immediately opens or reuses a
  pending direct connection for every target. `source` is `autoReconnect` or
  `manualReconnect`; manual activation promotes the same pending session rather
  than opening a duplicate connection. It returns one acknowledgement per
  target: `resolved` means native owns a stable UUID/address,
  `identityPending` means iOS owns an exact config/name identity awaiting a
  CoreBluetooth UUID, and `rejected` means no native reconnect owner exists.
  Callers must not treat desired targets as active until an acknowledgement is
  accepted; missing, duplicated, or unknown acknowledgement states fail closed.
- `notifyAutoReconnectTargetVisible(uuid, name)` is a scan hint, not a second
  connection owner. Android returns `true` only when it takes over that exact
  target's pre-physical passive GATT or pending retry and queues one serialized
  `connectGatt(autoConnect=false)` attempt. It keeps the same autoReconnect
  source and long-lived passive owner after that direct attempt ends. iOS returns
  `false` because CoreBluetooth pending connect and State Restoration remain
  authoritative.

Every reconnect status event carries `source`, `generation`,
`sessionGeneration`, and `attemptGeneration`. `generation` is retained as the
serialized compatibility key and always equals the Dart session generation.
`attemptGeneration` is the platform Gate/callback ownership generation. For
legacy or non-session callers, native falls back `sessionGeneration` to the
attempt generation. Old payloads decode as `source=unknown`,
`sessionGeneration=0`, and `attemptGeneration=0`.

## State Flow

Native auto reconnect reuses the existing connection states:

```text
connected
  -> disconnectFromSys
  -> [native pending direct connect; no visible state]
  -> contactDevice(source, generation)
  -> searchService
  -> searchChars
  -> connectFinish
  -> connected
```

No new EventChannel is required. Automatic reconnect must not emit `connecting`
before a physical callback. Existing terminal states (`timeout`, `serviceFail`,
`charsFail`, `noDeviceFound`) describe one attempt and do not delete the task.

## Reconnect Task Lifecycle

Each platform keeps one reconnect task per device:

```text
belongConfig
uuid
name
sn or mac
attempt
pending native connection handle owned by the OS
pausedByBluetoothOff
awaitingRecoveryActivation
attempt source
sessionGeneration
attemptGeneration
```

The task is normally armed after `deviceConnected(uuid)`. On a later cold start,
Dart may seed the already-bound targets and activate them immediately; this is
still recovery of a previously authorized owner, not retry of an unknown
first-connect failure.

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

Pause the task on Bluetooth off. When Bluetooth returns to powered on, native
sets `awaitingRecoveryActivation` and resets the source to `autoReconnect`, but
does not open a GATT with the pre-reset session. Dart first combines every
eligible glasses/ring endpoint into one final recovery session, then
`activateAutoReconnectTargets` consumes the barrier and creates the only
physical owner. This prevents an old-session callback from racing the combined
batch and being closed immediately by an exact session rebind.

## Trigger Rules

Schedule reconnect when all are true:

- The device's `BleConfig.autoReconnect == true`.
- The device has reached business `connected` before, or Dart has seeded it from the bound-device cache.
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

## Pending Session and Timeout Boundary

Native reconnect is a persistent intent after `deviceConnected(uuid)`. Reaching
`autoReconnectMaxAttempts`, `timeout`, `noDeviceFound`, `serviceFail`, or
`charsFail` must not delete the task.

Waiting in the global admission queue is not part of `connectTimeout`. The
business-pipeline timeout starts only after a real
`STATE_CONNECTED` / `didConnect` callback has been granted the Gate. On Android,
an `initiateBinding=true` owner may first hold that same Gate while system bonding
completes; service discovery starts only after `BOND_BONDED`. The timeout remains
active through bonding and `connectFinish` until final
`deviceConnected`, with the existing bounded auth grace.

Android bounds only the pre-physical-callback lifetime of each pending
`connectGatt(autoConnect=true)` by `BleConfig.connectTimeout` (minimum 1s). On
expiry it first classifies the exact owner as pre-physical, Gate-admitted,
business-connected, or stale. Only an exact pre-physical owner is normally
recycled. Gate-admitted and business-connected owners keep their GATT. A stale
Supervisor/Manager/Gate identity is repaired explicitly: the orphan is removed,
and a replacement is created only when Manager does not already own another
healthy GATT. No boolean failure path may silently preserve a fake owner.
Consecutive
pre-physical deadline failures rebuild after 1.5s for failures 1–3, 5s for
failures 4–10, and 30s from failure 11 onward. A matching scan-visible hint
resets the streak and rebuilds after a 250ms debounce. This refresh is
native-only: it neither emits Dart/UI `timeout` nor deletes the long-lived
reconnect task. Receiving `STATE_CONNECTED` cancels this deadline before Gate
admission, so a queued GATT is never recycled while waiting for another endpoint.
iOS immediately leaves a known `CBPeripheral` pending in CoreBluetooth; its
pending connect is not recycled by this Android-specific deadline.

## Global Connection Admission Gate

All targets may be pending at the physical-link layer at the same time. From
the first physical callback onward, one process-wide Gate serializes service
discovery, characteristic discovery, CCCD/notify setup, and business auth:

- automatic callbacks enter FIFO order;
- a manual reconnect already waiting is preferred over automatic waiters;
- manual never preempts the active owner;
- queue time is excluded from the timeout;
- `connectFinish` does not release the owner;
- business `deviceConnected`, or an acknowledged terminal teardown, releases
the owner and starts the next endpoint.

On Android the active Gate also serializes proactive system bonding for configs
with `initiateBinding=true`. A `BONDING` owner keeps the Gate; `BOND_BONDED`
resumes service discovery on the exact GATT/session, while an explicit
`BOND_BONDING -> BOND_NONE` terminates that session before the next owner starts.
Configs with `initiateBinding=false` skip plugin-owned `createBond()` and enter
service discovery directly.

Every admission is identified by endpoint + attemptGeneration + session and, at
the platform boundary, the exact GATT/peripheral object. Status events expose
the Dart sessionGeneration separately so a reconnect batch can remain stable
while native retries advance attempt ownership. Stale callbacks fail closed.

Android Manager and Gate maintain the same per-endpoint attempt-generation
high-water mark. A batch cancellation advances that mark exactly once before
tearing down its endpoint runtimes; the per-endpoint release step must not
advance it again. A later attempt is allocated from the maximum high-water mark
observed by either side. This keeps a valid post-cancellation physical callback
from being rejected as stale after OTA, device switching, or repeated cleanup.

## GATT Restoration Readiness

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

Reconnect activation always calls
`BluetoothDevice.connectGatt(..., autoConnect=true, ...)` for every target. It
does not first enter `connect(...)`, scan-refresh, or the scan-then-connect
queue. The app may scan concurrently for at most 20 seconds, but scan visibility
is not an admission prerequisite. When that auxiliary scan does confirm an
unresolved target, Android atomically replaces only its exact pre-physical
passive GATT with one globally serialized `connectGatt(..., autoConnect=false,
...)` attempt; this is an acceleration path, not a second owner or a UI state.

Each Android passive handle has an exact pre-physical deadline as described
above. The deadline must compare the GATT object and admission generation before
closing; a late callback from an expired handle must fail closed and a GATT that
has reached the Gate must remain alive until normal terminal teardown.

After business `deviceConnected` releases the Gate, the live GATT remains the
physical owner. Android stores its exact admission metadata and GATT identity.
A later `STATE_DISCONNECTED` from that exact `(sessionId, GATT)` must still emit
`disconnectFromSys`, clear the task's `passiveGatt`, and create a new passive
handle. A callback from any older GATT/session must not change the newer
attempt.

On Bluetooth-on, Android does not replay paused tasks by itself. It waits for
the Dart recovery activation carrying the final `sessionGeneration`; ordinary
`arm` calls cannot consume this barrier. Manual promotion also classifies the
native owner first. A stale `passiveGatt` is repaired or dropped instead of
being reported as reusable, while a real Gate/business owner is never closed.

## iOS Strategy

iOS uses CoreBluetooth pending connects without an internal scan-first phase.
After a previously business-connected device disconnects, the app hands a known
`CBPeripheral` back to CoreBluetooth immediately. That pending `connect` is the
preserved operation that can wake or relaunch the app later.

iOS lookup order:

1. `retrieveConnectedPeripherals(withServices:)`, using configured private services plus ANCS.
2. `retrievePeripherals(withIdentifiers:)`.
3. If a peripheral is known, call `centralManager.connect` immediately with the native reconnect option when available.
4. If no peripheral is known, keep the task armed and wait for the app's
   concurrent scan/cache update or a later retrieve/restoration opportunity.

After reinstall, a server-restored UUID can be stale while the matching endpoint
is already system-connected and no longer advertising. The first lookup therefore
matches either the stable UUID or the exact non-empty endpoint name; when it finds
a new CoreBluetooth UUID, identity migration must finish before admission is
registered. The migrated peripheral then uses the existing Gate/GATT pipeline.

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

`connectedDevices` is only a per-process business/GATT cache, never the source
of truth for a physical iOS link. It is keyed by stable CoreBluetooth UUID, not
the `CBPeripheral` object identity: retrieve/restoration may return a different
object instance for the same UUID. A reconnect may skip `centralManager.connect`
only when the cache is business-connected **and** that peripheral's physical
state is `.connected`. On every terminal state all same-UUID cache entries are
invalidated; before a new pending attempt they are replaced by one current
peripheral entry. This prevents a stale `isConnected=true` entry from silently
leaving an autoReconnect task armed without a CoreBluetooth pending connect.

Non-CoreBluetooth terminal states must not release the global Gate until
`didFailToConnect` / `didDisconnect` acknowledges teardown. A bounded 2-second
watchdog prevents permanent blocking when CoreBluetooth omits the callback.
Timed-out cancellation debt is stored as one saturating counter per endpoint,
not an array. Late callbacks consume debt before an active barrier; however, if
the new generation has already reached business `connected`, a real
`didDisconnect` must continue through normal cleanup/reconnect instead of being
swallowed as old debt.

After an acknowledged terminal releases admission, iOS must remove the old
active request before scheduling the next generation. Barrier completion owns
this ordering for deferred teardown; the ordinary terminal path must use the
same cleanup-before-schedule rule and must not schedule a second time.

Before Bluetooth-off teardown clears admission, each platform snapshots the
active sessionGeneration for connecting endpoints. A business-connected
reconnect task keeps its last successful sessionGeneration. The emitted
`disconnectFromSys` reuses that accepted sessionGeneration through the
compatibility `generation` key instead of falling back to
`source=unknown, generation=0`.

If a concurrent scan finds the same stable device name under a new
CoreBluetooth UUID, task, persistence owner, and Gate identity migrate
atomically before admission. Each canonical target retains at most two direct
aliases: the earliest UI owner and the most recent old identity. This preserves
hard cancel reachability without linear memory growth.

## even_connect Integration

1. Enable `autoReconnect` on the desired `BleConfig`.
2. On cold start, Bluetooth recovery, or reconnect entry, call
   `activateAutoReconnectTargets` once with all bound endpoints. Use
   `manualReconnect` only for a user click; otherwise use `autoReconnect`.
   Keep desired, activation-in-flight, and native-accepted targets separate so
   a rejected or lost acknowledgement cannot leave a phantom active batch.
   While Bluetooth is unavailable, system-disconnect callbacks may update
   business state but must not create per-endpoint activation sessions.
   Bluetooth available consumes that recovery debt once and submits the
   combined endpoint set.
3. Start the app-level scan concurrently, never before direct activation. Stop
   it when all devices connect or at 20 seconds, whichever comes first. A later
   Bluetooth-on recovery trigger may reopen only this scan window for the same
   native owner; it must not activate the targets again or advance generation.
4. For G2, keep `scan.matchCount = 2`; scan aggregation must not serialize the
   native direct attempts.
5. Keep listening to `connectStatusEC`. Show automatic "connecting" UI only
   after a reconnect-owned status callback actually arrives. Hide that UI after
   one minute without cancelling native reconnect. A manual request uses the
   same one-minute display timeout and may show a timeout prompt, but still does
   not cancel native reconnect.
6. Stop running a parallel Dart reconnect loop for native-managed configs.
7. On `connectFinish`, send G2 `AUTHENTICATION(0x04)` through `UX_DEVICE_SETTINGS_APP_ID(0x80)` with `AuthMgr.secAuth = true`, the platform-specific `phoneType`, `syncBoth = false`, `timeout = 500ms`, and `maxRetry = 1`.
8. Wait for the `DevCfgDataPackage` callback. Only when `authMgr.secAuth == true`, call `devicePreConnected(uuid)` to enter the bounded auth grace window.
9. For the right leg, send `PIPE_ROLE_CHANGE(0x05)` with `asCmdRole = RIGHT`, then send `TIME_SYNC(0x80)` with the current timestamp and 15-minute timezone unit.
10. Call `deviceConnected(uuid)` in the post-auth `finally` path so native can publish the final `connected` state and release the Gate.
11. Any visible cancel action is a hard cancel: call `disconnectDevice`, stop
    automatic connection, and do not reactivate until the next explicit manual
    connect.

## Acceptance Matrix

- User disconnect does not reconnect.
- A visible cancel is a hard cancel; a one-minute UI timeout alone is not.
- All endpoints enter pending direct connect before the concurrent scan starts.
- Concurrent scan stops at all-connected or 20 seconds.
- Automatic UI appears only after a reconnect-owned status callback and hides
  after one minute without stopping native reconnect.
- Device power loss then power restore reconnects to `connectFinish`.
- All private services are writable and notify-capable after reconnect.
- Bluetooth off pauses tasks; Bluetooth on waits for one final combined Dart
  activation before native opens replacement GATT handles.
- Bluetooth-off terminals preserve the active or last business-connected
  generation, so Dart can accept the disconnect before reconnect resumes.
- iOS ANCS/system-connected devices do not fall into scan timeout.
- Android out-of-range devices recover through the mandatory passive reconnect path.
- Android business-connected system disconnect rebuilds `passiveGatt`; an old
  GATT/session cannot terminate a newer attempt.
- iOS repeated cancellation watchdog expiry remains constant-memory, and a live
  system disconnect is not hidden by old cancellation debt.
- Repeated iOS UUID drift keeps at most two aliases per canonical target.
- Long out-of-range periods do not stop native reconnect unless user/business explicitly cancels it.
- OTA state is not hijacked by normal auto reconnect.
- Authentication hang after `connectFinish` times out and retries instead of getting stuck.
- G2 scan results are displayed only after both legs are matched by `matchCount = 2`.
- G2 is marked business-connected only after `AUTHENTICATION` returns `authMgr.secAuth == true`; right-leg `PIPE_ROLE_CHANGE` and `TIME_SYNC` run before final `deviceConnected`.
