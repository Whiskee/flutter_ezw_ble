# BLE Issue Playbook

## iOS restoration: one G2 leg disconnects before current targets load

Symptoms:

- `willRestoreState` returns both G2 peripherals, and one leg is already physically connected.
- Before Flutter loads the current account's bound targets, that leg reports `didDisconnectPeripheral` with `isReconnecting=false`.
- Native logs then report that it is not the current connected device; the other leg reconnects, while the first leg stays absent until a later manual attempt.

Root cause:

- A restored peripheral is a system-owned physical opportunity, not yet a business owner.
- The old startup path only cached the object while configs were unavailable. If it disconnected before target activation, normal terminal handling could not find an active request or business cache and therefore did not rebuild a CoreBluetooth pending connect.
- Matching immediately after `initConfigs` is also unsafe: config type alone cannot prove that a restored endpoint belongs to the current account.

Fix:

- Put every restored peripheral into a UUID-level `idle / pending / connected` physical escrow.
- Before claim, hold `didConnect` without service discovery, notify, AUTH, or `noBleConfigFound`; on terminal, keep an existing system reconnect or re-arm one long-lived auto-reconnect pending connect.
- Let `activateAutoReconnectTargets` claim by stable UUID or unique exact endpoint name. Attach the current admission to an existing `.connecting` request instead of opening a duplicate connect.
- Finalize only after all current G2 legs and R1 targets have returned activation acknowledgements. Cancel unclaimed historical objects behind the late-callback cancellation barrier.

Owner:

- `flutter_ezw_ble` iOS native owns restoration escrow, claim, re-arm, and hard-cancel isolation.
- even_connect owns submitting the complete current target batch before calling `finalizeStateRestorationClaims`.

## iOS State Restoration crashes without bluetooth-central background mode

Symptoms:

- App crashes on iOS startup or plugin initialization.
- Xcode shows `NSException` with `State restoration of CBCentralManager is only allowed for applications that have specified the "bluetooth-central" background mode`.
- There may be no BLE scan/connect logs because the crash happens while creating `CBCentralManager`.
- With the safe gate in place, hosts that omit the mode should log `stateRestoration: WARNING disabled because host Info.plist is missing UIBackgroundModes bluetooth-central`.

Root cause:

- `CBCentralManagerOptionRestoreIdentifierKey` enables CoreBluetooth State Restoration.
- Apple requires the host app to declare `UIBackgroundModes = bluetooth-central` before a central manager can be initialized with that restore identifier.
- Passing the restore identifier unconditionally makes any host app or example without that plist mode crash before normal BLE logic starts.

Fix:

- Gate `CBCentralManagerOptionRestoreIdentifierKey` behind a runtime `Info.plist` check for `UIBackgroundModes.bluetooth-central`.
- If the mode is missing, initialize `CBCentralManager` without a restore identifier so foreground BLE still works and State Restoration is simply disabled.
- Keep the missing-mode warning actionable: it must say that iOS background reconnect / CoreBluetooth State Restoration is disabled and that the host should add `UIBackgroundModes -> bluetooth-central` to `Runner/Info.plist`.
- Add `UIBackgroundModes` / `bluetooth-central` to examples or host apps that need iOS background reconnect and State Restoration.

Owner:

- `flutter_ezw_ble` iOS native owns the safe initialization gate.
- The host app owns declaring `UIBackgroundModes.bluetooth-central` when it wants State Restoration.

## Android passive autoReconnect closes the live GATT after business connected

Symptoms:

- After turning Bluetooth off and on, the app UI reports `connected`, but Android system Bluetooth shows no connected BLE devices.
- Native logs show `Set <uuid> connected`, then immediately `BluetoothGatt.close()` / `unregisterApp()` for the same `clientIf`.
- Follow-up commands fail with `write start failed, drop queued command` even though Dart still believes the device is connected.

Root cause:

- Passive reconnect stores the pending/live `BluetoothGatt` in `BleReconnectTask.passiveGatt`.
- When Dart later calls `deviceConnected(uuid)`, `BleManager.handleConnectState(CONNECTED)` arms the long-lived reconnect task again.
- The existing task refresh path closed `task.passiveGatt` unconditionally, which closes the same GATT session that just reached business `connected`.
- Because the close is self-inflicted during the success path, Dart can receive `connected` without an immediate matching disconnect event, creating a false-connected UI.

Fix:

- When refreshing an existing Android reconnect task during business `connected`, compare `task.passiveGatt` with `device.myGatt`.
- If it is the live connected session, cancel the watchdog and clear `task.passiveGatt` ownership without closing the GATT.
- Continue closing non-live stale passive GATT handles during retry/cancel/watchdog paths.

Owner:

- `flutter_ezw_ble` Android native autoReconnect supervisor.

## G2 demo: both legs connect, then UI reports connect failure

Symptoms:

- Android log shows two `BluetoothGatt.connect()` calls for the same G2 pair in the same user action, one for the left leg and one for the right leg.
- Both peripherals may still reach GATT success, service discovery, notify setup, and G2 command writes.
- Flutter later throws `Navigator operation requested with a context that does not include a Navigator`, so the user sees the connection as failed even though BLE/protocol work already succeeded.

Root cause:

- G2 has two independent BLE peripherals. Starting both native connections together is allowed when each command/pending response is keyed by `uuid + serviceId + magicRandom`.
- The business layer still needs one logical whole-device state: the whole G2 is connected only after both legs reach business `connected`.
- A `BuildContext` owned by the widget that returns `MaterialApp` is above the `Navigator`; route changes from that context fail.
- During reconnect, stale `disconnectByUser` events from closing the previous GATT may arrive after the new connect flow has started. Treating every disconnected state as fatal makes the UI show failure while the new native/protocol flow is already succeeding.
- Without an app-level connect watchdog, a missing `connectFinish` or AUTH callback can leave `_connecting` true forever, so the reconnect button appears to do nothing.
- If the detail page is a separate route and only rebuilds from a log `ValueNotifier`, parent `setState(() => _connecting = true)` will not immediately update the detail button. The native reconnect can start while the UI still shows the old label.

Fix:

- Start both legs if the product flow wants faster connection.
- Aggregate the selected `BleMatchDevice` states and only enter the detail/whole-device connected UI after every leg is business `connected`.
- If any selected leg emits an error or system disconnect during the connect attempt, stop the whole-device connect flow and invalidate pending AUTH callbacks so a late response cannot revive the flow.
- Ignore stale `disconnectByUser` while a new connect attempt is active; explicit user disconnect already owns its local cleanup path.
- Add a bounded app-level connect watchdog so the UI can leave `Connecting` and allow another attempt if an expected event never arrives.
- Notify the detail route when connection UI state changes, not only when a log line is appended.
- Use a `GlobalKey<NavigatorState>` or a child context under `MaterialApp` for detail navigation.

Owner:

- App/example/even_connect orchestration. `flutter_ezw_ble` native code should continue to own one peripheral connection at a time and should not decide cross-leg business ordering.

## iOS connectDevice decode fails before connecting

Symptoms:

- UI stays in `Connecting`.
- iOS logger prints `Swift.DecodingError.typeMismatch(Swift.Bool, ...)` for `afterUpgrade`.
- There is no CoreBluetooth `connect-flow`/`didConnect` evidence for that attempt.

Root cause:

- Dart `connectDevice` exposes `afterUpgrade` as nullable for API compatibility.
- Passing the nullable value directly through MethodChannel serializes `afterUpgrade: null`.
- iOS decodes the MethodChannel map into `BleEasyConnect`, where `afterUpgrade` is a non-optional `Bool`, so JSON decoding fails before native connection starts. Android does not fail because it manually reads `as Boolean? == true`.

Fix:

- Dart MethodChannel should send `afterUpgrade: afterUpgrade ?? false`.
- iOS MethodChannel should normalize missing/null `afterUpgrade` and `directConnect` to `false` before decoding, to remain compatible with older callers.

## G2 demo: left leg appears connected, right leg pairs only on second attempt

Symptoms:

- Console only shows a few lines, so it is unclear whether the right leg reached physical `connectFinish`, AUTH send, AUTH callback, or final business `connected`.
- UI can report the whole G2 connect flow as failed while later logs suggest one leg has already completed.
- A second manual connect attempt may trigger the missing right-leg AUTH/paired callback and then the whole device succeeds.

Root cause:

- G2 is a two-peripheral logical device. The app must log and aggregate each leg independently, then compute one whole-device connected state.
- `_addLog` only updating the in-app list makes terminal `console.log` incomplete; native `BleEC.logger` and Dart orchestration lines are easy to miss when diagnosing from terminal output.
- Logs that only print a UUID or a single state event do not show whether the other leg is pending, stale, or already connected.

Fix:

- Mirror demo `_addLog` to `debugPrint` so terminal capture includes native logger events and Dart orchestration logs.
- For every selected G2 connect state, log leg label, name, short UUID, MAC, epoch, and aggregate snapshot.
- For G2 protocol callbacks, log command id, magic number, transport success, CRC, `authSecAuth`, and whether a pending command matched.
- On iOS, log `connectDevice` decoded arguments, `connectStatus -> Flutter`, service match counts, and notify subscription progress.

Owner:

- App/example/even_connect orchestration owns whole-device aggregation and console observability.
- `flutter_ezw_ble` native owns per-peripheral CoreBluetooth/GATT progress reporting.

## G2 demo: first AUTH connect fails, second tap succeeds

Symptoms:

- The first manual connect reaches iOS/Android GATT progress and may even receive later G2 packets, but UI exits `Connecting` as failed.
- A second tap succeeds quickly with the same pair.
- Logs around `AUTHENTICATION` show an initial ACK-like packet with `authSecAuth=null`, while the real success condition is a later packet with `authSecAuth=true`.

Root cause:

- G2 `AUTHENTICATION` is not a simple request/response where the send Future proves business success.
- The transport ACK can arrive separately from the documented auth-success callback.
- First-time pairing/bonding can delay the `authSecAuth=true` callback beyond the short send wait timeout.
- If the demo treats the send wait timeout as fatal, it clears auth epoch/active state and later genuine success is ignored as stale. The second tap then succeeds because the device/system pairing path is already warm.

Fix:

- Treat `sendDataPackage(AUTHENTICATION)` completion as "command delivered/ACK observed" only.
- Keep waiting for the real `authMgr.secAuth == true` callback before `devicePreConnected` / `deviceConnected`.
- Do not stop the whole G2 connect flow on the short AUTH send wait timeout; log it and keep the active auth head alive.
- Add a separate bounded AUTH-success watchdog so a truly missing callback still fails cleanly.

Owner:

- App/example/even_connect protocol orchestration owns this. Native BLE should continue to report `connectFinish` only after private services and CCCD are ready.

## G2 demo: first tap appears ignored and second tap succeeds near timeout

Symptoms:

- The user taps connect/reconnect and sees little or no visible reaction.
- A later retry reaches connection progress but appears to succeed only near the failure boundary.
- Logs can show `connectFlow start` from cached-device restore before the manual tap, or a whole-device watchdog firing while the second G2 leg is still progressing.

Root cause:

- The demo blocks repeated connect calls while `_connecting == true`, but the old guard returned silently without a log or UI nudge.
- Cached-device auto recovery can already be running when the user taps, so the tap is ignored even though a native connection is in flight.
- G2 is currently connected serially by leg. A fixed 30s whole-device watchdog is too short for two legs when each native leg has a 20s connect timeout plus GATT/notify/AUTH work.

Fix:

- Log repeated connect/reconnect taps as `connectFlow ignored` or `reconnect ignored` with the current aggregate state.
- Detect stale `_connecting` state when there is no watchdog or the watchdog window has already elapsed, clear the old session, then start a fresh one.
- Size the whole-device watchdog by leg count instead of using a fixed 30s timeout.

Owner:

- App/example/even_connect orchestration. Native BLE timeouts should still guard one peripheral connection, while the app-level watchdog guards the logical two-leg device.

## CDM / iOS restoration wakes the process but does not mean business connected

Symptoms:

- Android `CompanionDeviceService.onDeviceAppeared` fires, but G2 UI should not immediately show connected.
- Android logcat shows `Start proc ... for service {...EzwCompanionDeviceService}` after a companion device appears, but manually opening the app later still shows the normal splash screen.
- iOS `willRestoreState` fires after system relaunch, but receive data/AUTH callbacks may not be available until Flutter listeners attach.
- Logs show platform wakeup before `connectFinish`.

Root cause:

- Android CDM and iOS CoreBluetooth restoration are process/physical-link recovery layers.
- Android CDM binds the app's `CompanionDeviceService` in the background. It does not launch `MainActivity`, bring the app to the foreground, or restore the previous Flutter route. A later launcher tap can still create a fresh Activity and show the splash screen even though the process was already running in the background.
- They do not restore private GATT services, CCCD/notify, G2 AUTH, right-leg pipe switch, or time sync by themselves.
- Flutter EventChannel logs may be absent during a CDM service cold start because no Flutter UI/listener is attached yet. Use system logcat markers (`CDM_CompanionAppBinder`, `Start proc ... for service`, `CDM_CompanionServiceConnector connected=true`) and buffered native reconnect events to prove the wake path.

Fix:

- Treat CDM/restoration as an outer wakeup signal only.
- Reuse the existing native GATT restoration gate before `connectFinish`.
- Keep G2 business commands in Dart/even_connect after `connectFinish`.
- Buffer native restoration logs/status until EventChannel listeners attach.
- If product requirements demand business connect while no Flutter UI/engine exists, move the required G2 post-`connectFinish` protocol handshake into native code or start a deliberate headless Flutter execution path from the companion service. Do not infer foreground UI launch from CDM service binding.

## Android CDM wake path must cover modern presence events

Symptoms:

- CDM association exists and `dumpsys companiondevice` shows the device, but the app is not woken when the device returns.
- `CompanionDeviceService` is declared, but logcat only shows partial CDM events or no callback after Bluetooth is toggled.
- A demo using Android 16 / compileSdk 36 wakes reliably, while the plugin using `onDeviceAppeared(String)` is less deterministic.

Root cause:

- `onDeviceAppeared(String)` / `onDeviceDisappeared(String)` are legacy callbacks. Newer Android CDM presence dispatch distinguishes `EVENT_BLE_APPEARED`, `EVENT_BT_CONNECTED`, `EVENT_BLE_DISAPPEARED`, and `EVENT_BT_DISCONNECTED`.
- `startObservingDevicePresence(String address)` loses the association id and cannot express the newer `ObservingDevicePresenceRequest` flow.
- Repeated association can create duplicate association rows for the same MAC, causing repeated callbacks or racing reconnect attempts.
- If the host app declares more than one `CompanionDeviceService`, Android may choose a different primary service unless `android.companion.PROPERTY_PRIMARY_COMPANION_DEVICE_SERVICE` is set.

Fix:

- Prefer `getMyAssociations()` / `AssociationInfo.id` and `ObservingDevicePresenceRequest.Builder().setAssociationId(id)` on API levels that support them; keep string-address fallback only for older Android.
- Handle both BLE appeared and BT connected as "device available" wake signals. Do not treat BLE disappeared as a definitive disconnect when GATT may already be connected and advertising has stopped.
- On app start, refresh existing observations with stop/start and remove duplicate associations for the same MAC.
- If the plugin's companion service must own the wake path, mark it as the primary companion service or ensure the host app has no competing `CompanionDeviceService`.

## Android CDM reconnect appears for both legs but one leg is unstable

Symptoms:

- After Bluetooth is turned off, the app process is killed, and Bluetooth is turned on again, CDM wakes the app and one G2 leg reaches GATT connected.
- The other leg may show `status=22`, missing business `connected`, or require another manual reconnect.
- Logcat shows several callbacks for the same association: `EVENT_BLE_APPEARED`, `EVENT_BT_CONNECTED`, `onDeviceAppeared(String)`, and `onDeviceAppeared(AssociationInfo)`.
- Android GATT logs show multiple `connectGatt(auto=true)`, `discoverServices()`, `close()`, or `Client registration completed after closed` for the same MAC.
- A `connectGatt(auto=true)` log for one MAC can be followed by callbacks for the other MAC, proving an old GATT callback is still mutating current state.
- During CDM service-only wake, logcat has native service/process markers but no `I/flutter` G2 business logs, so AUTH/pipe/time-sync should not be assumed to have run.

Root cause:

- Modern CDM can deliver both modern presence events and legacy/association callbacks for the same physical appearance.
- Treating every appeared callback as a new reconnect attempt creates multiple GATT instances for the same peripheral.
- A later duplicate attempt can close or unregister the GATT that already reached service discovery, so the logical G2 aggregate sees only one stable leg.
- A global CCCD descriptor queue lets concurrent left/right service discovery consume each other's notify descriptors.
- A global send queue lets a write callback from one leg pop and start a command intended for the other leg.
- Stale callbacks from a closed/replaced `BluetoothGatt` must not update connect state for the current `BleDevice`.
- Ignoring `status=22` after stale callbacks are filtered hides real current-GATT disconnects and prevents reconnect scheduling.
- This is a per-peripheral idempotency bug in `flutter_ezw_ble`; the native plugin still should not decide whole-G2 business success.

Fix:

- Deduplicate CDM appeared callbacks per UUID in a short window.
- Make `beginReconnectAttempt` idempotent for a UUID: if the same UUID is already reconnecting, flow-connecting, or business connected, ignore the duplicate trigger.
- Keep different UUIDs independent so G2 left/right can reconnect in parallel.
- Scope CCCD descriptor queues to one `BluetoothGattCallback`, scope command queues by UUID, and only let the callback belonging to `device.myGatt` mutate state or drain writes.
- After stale GATT callbacks are ignored, let current-GATT `status=22` flow through `disconnectFromSys` so reconnect can be scheduled.
- Mirror native plugin logs to logcat, not only Flutter EventChannel, because CDM can wake only the companion service before Flutter attaches listeners.
- Preserve Dart/even_connect ownership of post-`connectFinish` AUTH, pipe switch, time sync, and whole-device aggregation.

## iOS restoration/cold launch opens detail but shows disconnected

Symptoms:

- The G2 was business connected before the app was killed or relaunched.
- After the process appears again, the example restores the cached SN/name/MAC and opens the detail page.
- The detail page shows `Reconnect` or disconnected even when the platform may have restored a physical CoreBluetooth peripheral.
- Console may show `connectFinish` or `stateRestoration` before the cached selected device has been restored into Dart state.

Root cause:

- Persisted example data stores device identity only, not the business connected state.
- `_connectStates` is in-memory and empty after process death, so the UI must not assume the cached device is connected.
- iOS restoration can emit `connectStatus` before `_selectedDevice` is restored. If Dart ignores that early `connectFinish`, G2 AUTH is never sent and `deviceConnected(uuid)` is never called.
- `connectFinish` is only the private-service/CCCD readiness gate; the whole G2 is business connected only after both legs finish AUTH and post-auth commands.

Fix:

- Cache the latest native `connectStatus` events by UUID even when no selected device exists yet.
- When restoring a cached G2, enter a fresh direct reconnect flow and preserve non-terminal early states.
- Replay early selected `connectFinish`/`connected` events after `_selectedDevice` is restored so G2 AUTH can run.
- Keep the UI in `Connecting` until both legs reach business `connected`; show `Reconnect` only after the fresh recovery attempt fails or is stopped.

## iOS example: Bluetooth turns on but cached device does not reconnect

Symptoms:

- The demo starts while iPhone Bluetooth is off.
- After Bluetooth is turned on, Flutter logs `bleState: BleState.available`.
- iOS native logs `centralManagerDidUpdateState: State = poweredOn, code = 5`.
- No `restore cached device`, `connectFlow start`, `connect-flow request`, or `Start connect` log appears after `poweredOn`.

Root cause:

- `centralManagerDidUpdateState(.poweredOn)` only resumes native reconnect tasks that already exist inside the iOS plugin.
- A cold launch or hot restart can run the example's cached-device restore while Bluetooth is unavailable. The native call fails with a BLE unavailable/error state before a CoreBluetooth pending connect is created.
- Once that app-level restore attempt stops, the example previously only displayed the later `BleState.available` event. It did not submit the cached G2 identity to `connectDevice` again, so there was no native task for iOS to resume.

Fix:

- Track the latest BLE state and whether `initConfigs` has completed in the example layer.
- When `BleState.available` arrives after configs are ready, drain buffered native reconnect events and run a single guarded cached-device recovery pass.
- If no selected device exists, restore the persisted G2 identity and start a direct reconnect.
- If a selected device exists but is not business connected, start a direct reconnect from the detail page state.
- If the previous connection flow was started while BLE was off/unauthorized, stop that stale flow and restart it after Bluetooth becomes available.
- Keep iOS native responsible for CoreBluetooth pending connects and State Restoration after the app has submitted a reconnect task. Keep example/even_connect responsible for cached identity replay and G2 business AUTH after `connectFinish`.

Owner:

- App/example/even_connect orchestration owns retrying cached identity after Bluetooth becomes available.
- `flutter_ezw_ble` iOS owns resuming native reconnect tasks that were already armed before Bluetooth became unavailable.

## iOS cached reconnect times out on first leg after app relaunch

Symptoms:

- The example restores a cached two-leg device and starts reconnect automatically after app relaunch.
- Logs show the first leg reaches `connect-flow ... state = timeout`.
- The aggregate state remains like `Left leg=timeout, Right leg=none`, because the Dart demo connects legs serially and stops after the first terminal error.
- A scan may have seen the same physical device with a current broadcast local name, but the pending native connect request is not resumed.

Root cause:

- iOS stores a CoreBluetooth peripheral identifier, not the real BLE MAC address.
- A cached identifier can be stale across cold launch, restoration, reinstall, or CoreBluetooth cache churn. Blind `directConnect=true` can therefore call `central.connect` on a peripheral object that never completes and eventually times out.
- The iOS scan-then-connect path matched pending requests against `peripheral.name`, but CoreBluetooth often leaves `peripheral.name` empty during scanning. The real discoverable name is in `CBAdvertisementDataLocalNameKey`.
- Because the first leg timed out before the right leg was requested, the right leg never entered native connect.

Fix:

- For iOS cached/detail reconnect in the example, prefer scan/system-connected resolver instead of blind direct reconnect. Android can keep direct reconnect because it stores the real Bluetooth address.
- In the iOS native scan-then-connect path, pass the advertised local name into pending request matching and use it when updating the active connect request.
- Keep `retrieveConnectedPeripherals` in the route so devices already connected by the system can still skip scanning.

Owner:

- Example/even_connect owns cached identity replay and G2 leg sequencing.
- `flutter_ezw_ble` iOS owns robust scan-then-connect matching and CoreBluetooth route resolution.

## Example scan starts but no devices appear

Symptoms:

- The example logs `startScan: ok`, and BLE permission/state look normal.
- The scan list stays on `No BLE devices found`.
- Native scan callbacks may exist, but there is no `sendMatchDevices` / `scanResult` event reaching Flutter.
- The issue is easier to reproduce after reinstalling the app, clearing Bluetooth cache, or scanning devices that have not been connected before.

Root cause:

- BLE devices often advertise their user-facing name in the current advertisement local-name field.
- iOS `CBPeripheral.name` and Android `BluetoothDevice.name` are system cache fields. They can be empty during scan, especially before the device has ever connected or after app reinstall.
- If scan filtering reads only those cache names, the pipeline drops the advertisement before `nameFilters`, SN parsing, MAC parsing, and `matchCount` aggregation can run.

Fix:

- iOS scan parsing should read `CBAdvertisementDataLocalNameKey` first, then fallback to `CBPeripheral.name`.
- Android scan parsing should read `ScanRecord.deviceName` first, then fallback to `BluetoothDevice.name`.
- The resolved advertisement name must be used consistently for `nameFilters`, SN fallback, and the `BleDevice.name` sent to Flutter.
- iOS should include low-noise `scan/debug` logs for the first matched advertisement, MAC/SN drop, and partial `matchCount` aggregation. If only `startScan` appears and no `scan/debug` follows, the system did not deliver a matching discovery callback to the plugin.
- If scan still returns empty after this, inspect config JSON next: platform-specific G2 `snRule`/`macRule` values and `matchCount` must match the running platform.
- If iOS logs `scan/debug drop snRule` with Android-style offsets, the runtime JSON is wrong for the current platform. The example supports a `platformOverrides` / `platforms` section so one pasted config can provide different `scan.snRule` and `scan.macRule` values for iOS and Android without committing real device constants to source.

Owner:

- `flutter_ezw_ble` native scan pipeline owns resolving advertisement names and emitting scan results.
- App/example owns runtime config persistence and should log config name, `matchCount`, and scan permission state before starting scan.

## iOS Bluetooth off/on while app is debug-suspended does not schedule reconnect

Symptoms:

- G2 is business connected and native logs `autoReconnect: ... task armed`.
- Bluetooth is turned off, then native logs `autoReconnect: pause ... bluetooth off`.
- The process is suspended with `devicectl device process suspend`.
- After Bluetooth is turned back on and the process is resumed, the PID exists and the app may still receive some notify data, but no `autoReconnect schedule attempt` or `connect-flow request` appears.

Root cause:

- The paused reconnect tasks were only resumed from `centralManagerDidUpdateState(.poweredOn)`.
- In debug suspend/resume tests, the Bluetooth power transition can happen while the process is frozen, and the app may not observe a fresh `.poweredOn` delegate callback after `devicectl resume`.
- PID existence only proves the process object exists; it does not prove the app ran the CoreBluetooth state transition that resumes reconnect tasks.

## iOS example: Bluetooth permission request returns denied without showing a dialog

Symptoms:

- The demo prints `startScan blocked: BLE permissions not granted` on iOS.
- No iOS Bluetooth authorization dialog is shown when tapping scan.
- `Info.plist` already contains `NSBluetoothAlwaysUsageDescription`, so the missing usage string is not the first failure.

Root cause:

- `permission_handler_apple` compiles each permission strategy behind a Podfile preprocessor macro.
- The Bluetooth strategy is guarded by `PERMISSION_BLUETOOTH`; if the example Podfile does not define it, `Permission.bluetooth.request()` cannot execute the real CoreBluetooth permission strategy.
- Opening app settings is not a valid first-time authorization flow. The app should request permission and let iOS show the system dialog; settings are only useful after the user has already denied permission.

Fix:

- Add `PERMISSION_BLUETOOTH=1` to the example iOS Podfile `GCC_PREPROCESSOR_DEFINITIONS`.
- Keep `NSBluetoothAlwaysUsageDescription` in `Runner/Info.plist`.
- Do not automatically call `openAppSettings()` from the scan button. Log the denied status and block scanning until the user grants permission.
- Rebuild/reinstall the iOS app after changing the Podfile; uninstalling the old app is useful when the test device has stale denied permission state.

Fix:

- Keep `centralManagerDidUpdateState(.poweredOn)` as the primary path.
- Also kick paused reconnect tasks whenever the app becomes active/enters foreground, configs are reinitialized, or Dart queries `bleState`, if `centralManager.state == .poweredOn`.
- Log `autoReconnect: resume requested, reason=...` before scheduling attempts so suspend/resume tests have an explicit marker.

## iOS Bluetooth off/on is not a positive CoreBluetooth restoration test

Symptoms:

- Logs stop at `bleState: powerOff` / `centralManagerDidUpdateState: State = poweredOff`.
- Native logs `autoReconnect: pause ... bluetooth off` and `paused because bluetooth is unavailable`.
- After the app process is frozen with `devicectl device process suspend`, turning iPhone Bluetooth back on does not produce `poweredOn`, `start native pending connect`, `didConnect`, or `willRestoreState`.

Root cause:

- A CoreBluetooth pending connect can be preserved only while Bluetooth is available and the central has actually called `connect(peripheral, options:)`.
- When iPhone Bluetooth is powered off, CoreBluetooth cannot hold a meaningful pending BLE connection. The plugin correctly pauses reconnect tasks instead of creating a pending connect against an unavailable radio.
- `devicectl suspend` is a developer-tool freeze, not normal iOS background suspension. CoreBluetooth is not expected to thaw that process when Bluetooth is turned back on.
- Bluetooth power-on is not itself the BLE peripheral-return event used by State Preservation / Restoration.

Fix:

- For a positive iOS restoration/reconnect test, keep iPhone Bluetooth on and make the G2 leave/return by powering off, moving away, shielding, or otherwise dropping the peripheral link.
- Ensure logs show the app created a native pending reconnect while Bluetooth is still powered on: `start native pending connect` and `native pending connect armed without short timeout`.
- Let iOS background/suspend naturally for wake testing. Treat `devicectl suspend` and `devicectl --kill` as negative/control tests, not proof that real system restoration is broken.
- If testing the Bluetooth off/on path, resume/foreground the app or trigger `bleState` query after Bluetooth is on so the app can run and create a fresh pending connect.

## iOS native reconnect must be a CoreBluetooth pending connect, not an app timer

Symptoms:

- The device leaves for a long time while the app is backgrounded, suspended, or later restored by the system.
- App-level reconnect timers do not fire while the process is suspended.
- When the device returns, no immediate reconnect happens unless the user foregrounds the app or manually taps reconnect.

Root cause:

- iOS can preserve and restore CoreBluetooth work only when the central has an active system-owned operation, such as a pending `connectPeripheral`.
- A `Timer` scheduled inside the app process is not a wake source. Once the app is suspended or system-relaunched, the timer cannot discover the returning device.
- Short connect timeouts can accidentally cancel the pending CoreBluetooth connect before the peripheral returns.

Fix:

- After a business-connected device disconnects unexpectedly and `autoReconnectUseNativePassive` is enabled, immediately call `centralManager.connect(peripheral, options: ["CBConnectPeripheralOptionEnableAutoReconnect": true])` on the cached/retrieved peripheral.
- Do not start the short app connect timeout while the reconnect is merely pending in CoreBluetooth.
- Start the normal GATT/CCCD/protocol timeout after `didConnect`, then rediscover services, rewrite CCCD, and let Dart/even_connect send G2 AUTH / pipe switch / time sync.
- Keep timers only as foreground/manual-connect safety rails, not as the mechanism that waits for the device to return.

Owner:

- `flutter_ezw_ble` iOS owns the CoreBluetooth pending connect and restoration bridge.
- App/even_connect owns logical G2 aggregation and post-`connectFinish` business commands.

## iOS G2 one leg reaches didConnect, then times out at searchService

Symptoms:

- One G2 leg reaches `connectFinish`, sends `AUTHENTICATION`, receives `authSecAuth=true`, and reports business `connected`.
- The other leg logs `connect-flow ... from connected device list`, `didConnect`, and `connectStatus ... searchService`.
- The failing leg never logs `didDiscoverServices`, `didDiscoverCharacteristics`, `notifyProgress`, `connectFinish`, or `AUTHENTICATION`.
- A later retry may succeed after CoreBluetooth has warmed or replayed the cached GATT database.

Root cause:

- This is an iOS native per-peripheral GATT readiness issue, not a G2 AUTH failure.
- On reconnect/restoration/system-connected paths, CoreBluetooth can already hold a `CBPeripheral.services` cache when `didConnect` arrives.
- If the plugin only calls `discoverServices(...)` and waits for a fresh callback, a cached/restored peripheral can remain stuck in `searchService` until the connect timeout.
- Replaying cached services naively can duplicate characteristic and CCCD callbacks, so notify progress must be counted by unique read characteristic, not raw callback count.
- CCCD notify callbacks can also arrive before `didDiscoverCharacteristicsFor` has updated the local write/read characteristic dictionaries. If `connectFinish` is checked only inside the notify callback, de-duplicating later callbacks can leave the leg stuck until timeout even though all private services are already ready.

Fix:

- On every iOS `didConnect`/already-connected path, reset that peripheral's GATT readiness cache before service discovery.
- If all configured private services are already present in `peripheral.services`, process those cached services immediately instead of waiting for another `didDiscoverServices`.
- If cached service characteristics are already present, process them through the same helper as `didDiscoverCharacteristicsFor`; otherwise request characteristic discovery.
- Deduplicate discovered characteristics and notification-state callbacks so duplicate CoreBluetooth replays cannot over-count CCCD readiness.
- Emit `connectFinish` from a single readiness gate that is called after both characteristic discovery and notification-state updates. The gate should require all configured write chars, read chars, and unique notified read chars, so callback ordering does not matter.
- If a read characteristic is already `isNotifying` when characteristics are discovered, count it as notified immediately; restoration/cache paths may not deliver a new enable-notify callback.
- Keep G2 post-`connectFinish` business commands (`AUTHENTICATION`, pipe switch, time sync) in Dart/even_connect.

Owner:

- `flutter_ezw_ble` iOS owns the cached service/characteristic replay and unique CCCD readiness gate.
- App/even_connect owns two-leg aggregation and G2 protocol completion after native `connectFinish`.

## Android CDM is declared but no system discovery/association dialog appears

Symptoms:

- Android manifest contains companion permissions and a `CompanionDeviceService`.
- Dart/native exposes `getCompanionAssociations`, `startObserveCompanionDevicePresence`, and `removeCompanionAssociation`.
- User expects a system "find companion device" or association authorization dialog, but no dialog appears during normal BLE scan/connect.
- Logs may still show `CDM: device appeared` / `CDM: device disappeared`.

Root cause:

- CDM declarations and presence APIs do not launch the system association flow by themselves.
- The Android association dialog only appears after the app calls `CompanionDeviceManager.associate(...)` with a filter/request and starts the returned confirmation `IntentSender`.
- `startObservingDevicePresence(address)` requires an existing association, so calling it before `associate()` can only fail or no-op; it cannot create authorization.
- If an association already exists, the correct behavior is to skip the dialog and reuse it. Presence callbacks prove the system already knows this companion device.

Fix:

- Keep the plugin foundation as a passive bridge: list/remove associations, observe presence, and handle `CompanionDeviceService` callbacks.
- Add a separate Activity-aware onboarding API when the product flow is ready, for example `ensureCompanionAssociation(device)`.
- For G2, associate left and right endpoints separately, then mark the logical device CDM-ready only after both legs have an association.
- The association picker must run before the app consumes the BLE advertisement with a normal GATT connection; once the peripheral is connected it may stop advertising and CDM's own system scan may not find it.
- Log all CDM branches: already associated, association request, pending UI launch, result/cancel, and failure. This makes "no dialog because already associated" distinguishable from "no dialog because associate failed or was never called".
- To force a fresh dialog in the demo, use complete remove so both the BLE bond and companion association are removed before connecting again.

Owner:

- Host app / example onboarding owns the CDM association picker UX. `flutter_ezw_ble` can provide the native bridge, but should not silently launch system pairing UI from generic connect/reconnect.

## Android CDM dialog appears but BLE pairing dialog does not

Symptoms:

- Fresh install or reinstall shows the Android Companion Device Manager association dialog.
- No separate Android Bluetooth pairing/bond dialog appears.
- G2 private services and CCCD registration still complete.
- `AUTHENTICATION` may be suspected as not sending because the user did not see a pairing dialog.

Root cause:

- CDM association, Android BLE bond, and G2 protocol `AUTHENTICATION` are three separate layers.
- Uninstalling the app does not necessarily remove system Bluetooth bonds. If `BluetoothDevice.bondState == BOND_BONDED`, Android will not show a pairing dialog again.
- `BleConfig.initiateBinding` controls whether the plugin proactively calls `BluetoothDevice.createBond()` after GATT/CCCD/MTU setup. If it is false, Android only shows a pairing dialog when the Bluetooth stack itself needs security for an accessed characteristic.
- Some BLE pair flows are Just Works or OEM-managed and may complete without a visible confirmation UI.
- G2 `AUTHENTICATION` is a protocol command over the private service after `connectFinish`; it can send and return `authMgr.secAuth == true` even when there is no visible Android pairing dialog in that session.

Fix:

- Keep the G2 demo and even_connect defaults at `initiateBinding: false`
  unless the product explicitly requires Android system bonding. Do not use
  this switch to fix protocol `AUTHENTICATION` failures or reconnect races.
- Check `dumpsys bluetooth_manager` for `Bonded devices` and `Bond Events` before concluding that pairing did not happen.
- Check native logs for `start create bond`, `bond state`, `BleDevice: Send cmd ... is success`, `G2 receive ... cmd=0x4`, and `authSecAuth=true`.
- To force a fresh pairing dialog, remove both the BLE bond and the CDM association; reinstalling the app alone is not sufficient.

## Android scan fails with BLUETOOTH_SCAN SecurityException

Symptoms:

- Android log shows `BluetoothLeScanner.startScan(...)`.
- MethodChannel then fails with `java.lang.SecurityException: Need android.permission.BLUETOOTH_SCAN permission ... ScanHelper registerScanner`.
- Flutter receives `startScan: PlatformException(error, Need android.permission.BLUETOOTH_SCAN permission...)`.
- Native `Stop scan: scan call back is null` may appear after the failed scan start.

Root cause:

- Manifest declarations for `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` are not enough on Android 12+.
- The user must grant runtime Nearby devices permission before `BluetoothLeScanner.startScan`.
- `BleManager.checkBluetoothPermission()` only observes and publishes state; it does not show the runtime permission dialog.

Fix:

- Request runtime BLE permissions before entering `startScan`.
- On Android 12+, request `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`; keep location permission aligned with the app's scan/privacy policy and existing `currentBleState` checks.

## Android release scanResult JSON uses obfuscated keys

Symptoms:

- Android release build can scan and logs `Send match devices`, but the payload looks like `{"e":"S210...","f":[{"e":"g2","f":"Even G2..."}]}`.
- Flutter then throws `type 'Null' is not a subtype of type 'String' in type cast` from `_$BleMatchDeviceFromJson`, usually at `json['sn'] as String`.
- After scan is fixed, a similar crash can appear from `BleCmd.receiveMap` at `data["uuid"]` when GATT notify payloads are still sent through obfuscated `BleCmd.toMap()`.
- Debug builds may not reproduce the crash.

Root cause:

- Native Android outbound EventChannel payloads still used Gson/reflection serialization for `BleMatchDevice`, `BleDevice`, or `BleConnectModel`.
- `receiveData` used the same pattern through `BleCmd.toMap()`.
- R8 obfuscates Kotlin field names in release, so Gson emits obfuscated keys (`e/f/g/...`) while Dart generated models require stable keys such as `sn`, `devices`, `belongConfig`, `uuid`, `name`, `rssi`, and `connectState`.
- Fixing `initConfigs` parsing alone is not enough; inbound MethodChannel arguments and outbound EventChannel events both need release-stable serialization.

Fix:

- Do not use generic Gson/reflection serialization for Flutter channel contracts on Android release paths.
- Build scan and connect-status payloads with explicit `JSONObject` keys that match the Dart models.
- Build `receiveData` payloads with explicit `Map` keys: `uuid`, `psType`, `data` as Base64, and `isSuccess`.
- Keep `BleConnectState` values explicit camelCase strings and ensure Dart's converter handles every native state.
- Keep Dart receive parsers defensive so one malformed platform payload cannot terminate the EventChannel stream.
- If permission is denied, do not call native `startScan`; show a blocked log/state and let the app route the user to permissions/settings.

Owner:

- App/example owns when to prompt users. Use a third-party permission utility such as `permission_handler`; `flutter_ezw_ble` should not expose or own a native permission request bridge.

## Android release: initConfigs fails before scan/connection

Symptoms:

- `flutter run --release` or release APK starts successfully.
- The first app log shows `initConfigs: PlatformException(error, Abstract classes can't be instantiated! Adjust the R8 configuration ... Class name: ...`.
- Later scan/CDM logs show `CheckBleConfigIsConfigured: Bluetooth configuration has not been configured or not setting private service yet`.
- CDM may still report `device appeared`, but then logs `CDM: no reconnect task ...`.

Root cause:

- The Android MethodChannel `initConfigs` path used Gson reflection to convert nested `Map` payloads into `BleConfig`.
- Release/R8 obfuscation can remove or rename generic/signature metadata that Gson relies on, especially for classes extending shared abstract serializer bases.
- Since `initConfigs` fails, native `bleConfigs` stays empty. Scanning, connecting, and persisted reconnect restoration all become no-op or fail at the config guard.

Fix:

- Do not use generic Gson reflection for MethodChannel config payloads.
- Parse the fixed `BleConfig`/`BleScan`/`BleSnRule`/`BlePrivateService` map shape explicitly.
- Persist native reconnect config/target state with `JSONObject`/`JSONArray` rather than Gson, so CDM service cold starts are also release-safe.

Owner:

- `flutter_ezw_ble` Android owns native config decoding and reconnect persistence.

## G2 Android: one leg reaches connectFinish but never becomes connected

Symptoms:

- Android GATT logs show `onClientConnectionState status=0`, service discovery success, all private-service CCCDs written, MTU success, and `connectFinish`.
- Demo sends `AUTHENTICATION`.
- First AUTH response may log `success=true crc=true authSecAuth=null pending=true`, which is only the transport/pending ACK.
- A later packet may log `G2 receive devCfg decode failed ... payloadLen=6`, so no `authSecAuth=true` callback is observed.
- The other leg reaches `devicePreConnected` and `deviceConnected`, but the whole G2 does not navigate to detail/connected UI.
- Android native eventually logs `connect time out` for the stuck leg and clears its GATT.

Root cause:

- `connectFinish` is not business connected. Android intentionally keeps the connect timeout alive until Dart/even_connect calls `deviceConnected(uuid)`.
- The whole G2 connected state requires both legs to reach business `connected`.
- If the post-AUTH callback cannot be decoded as `DevCfgDataPackage` with `authMgr.secAuth == true`, Dart never calls `devicePreConnected/deviceConnected` for that leg.

Fix:

- Decode or log the raw DevCfg payload for the short packet before changing state semantics.
- Do not mark the stuck leg connected from `connectFinish`; that would hide protocol/auth failures and break private-service readiness guarantees.
- If the protocol defines an alternate already-authenticated or exception response shape, parse it explicitly and map only the documented success case to `deviceConnected`.

Owner:

- Protocol/example/even_connect layer owns AUTH response parsing and whole-device aggregation.
- Android native owns GATT/CCCD/MTU and should continue requiring explicit `deviceConnected` for final success.

## G2 Android: concurrent physical connect is OK, but first-time AUTH/bond should be serialized

Symptoms:

- Left and right GATT sessions can both reach `connectFinish` in one user action.
- The demo sends `AUTHENTICATION` to both endpoints close together.
- Android focus changes indicate a system pairing/bond dialog.
- Only one endpoint logs a bond completion such as `bond state: ... is bonded`.
- Only that endpoint later receives `AUTHENTICATION ... authSecAuth=true`; the other endpoint only sees `authSecAuth=null` ACKs and eventually times out.

Root cause:

- Two G2 BLE peripherals can connect concurrently, but Android's first-time security pairing/bonding UX is still a single system-mediated flow.
- Sending both G2 AUTH commands at the same time can make one endpoint win the bond/auth callback while the other remains physically connected but not business connected.

Fix:

- Keep physical `connectDevice` concurrent if the product wants faster startup.
- Serialize the G2 `AUTHENTICATION` business phase after `connectFinish`; when both legs are queued, prefer the right leg first because it owns the post-auth pipe role/time-sync path.
- Start the next endpoint's AUTH only after the active endpoint receives documented `authMgr.secAuth == true` and calls `deviceConnected`.

Owner:

- App/example/even_connect owns this sequencing. Native Android should continue reporting per-peripheral `connectFinish` independently.

## G2 Android: reconnect fails when both legs start native GATT at once

Symptoms:

- Manual first connect can eventually complete, but reconnect logs show left and right `connectGatt` requests started nearly together.
- Android native logs repeated or mixed `onClientConnectionState`,
  `onSearchComplete` / service discovery, descriptor writes, and later connect
  timeout for one or both legs even though notify/AUTH traffic may still appear.
- Some CCCD lines can show `enable descriptor and write = false`, followed by
  duplicate receive callbacks or a whole-device watchdog timeout.
- The UI may stay in `connecting` or report failure until another manual tap,
  where the remaining leg then completes.

Root cause:

- This is not a bond failure when `AUTHENTICATION` later succeeds or when
  `initiateBinding=false` is the intended G2 configuration.
- `connectDevice(...)` only means the native request was submitted; its Future
  does not mean GATT/CCCD/AUTH/business connection has finished.
- Android `BleManager` currently has global descriptor and send queues. If two
  G2 GATT sessions are bootstrapping simultaneously, callbacks from one
  `BluetoothGatt` can drain queue entries created by the other session.
- The logical G2 still needs a single whole-device state, so racing two native
  bootstrap flows makes failures hard to attribute and can leave one leg stale.

Fix:

- Serialize G2 reconnect at the business orchestration layer: request the first
  leg, wait until it reaches business `connected`, then request the next leg.
- Do not treat `connectDevice` completion as the serial boundary. The serial
  boundary must be `deviceConnected` / `connectStatus.connected`.
- Keep the existing serialized `AUTHENTICATION` queue as the protocol boundary
  after each leg reaches `connectFinish`.
- Also serialize Android native auto reconnect attempts. CDM/passive reconnect
  is started by `BleManager` timers and can bypass Dart/even_connect ordering,
  so it needs an `activeAutoReconnectUuid`-style gate that delays other UUIDs
  until the active UUID reaches `connected`, disconnected, or error.
- A deeper native hardening is to make Android descriptor/send queues per
  `BluetoothGatt` or per UUID, or add a native connection gate for devices that
  share one logical product.

Owner:

- App/example/even_connect owns logical G2 serial reconnect and aggregation.
- `flutter_ezw_ble` Android owns future per-GATT queue hardening if the generic
  plugin must support simultaneous same-config GATT bootstrap safely.

## G2: connectFinish queues AUTHENTICATION but no AUTH command is sent

Symptoms:

- Both legs, or one leg, reach native `connectFinish`.
- Demo/app log shows `connectFinish -> AUTHENTICATION queued` and `AUTHENTICATION queue size=... active=-`.
- No later log appears for `AUTHENTICATION start(serial)`, `AUTHENTICATION send start`, or `send G2 cmd ... commandId=0x4`.
- Device notifications may still show unrelated `cmd=0x6 ... authSecAuth=null pending=false`.
- Native eventually reports `timeout` because `deviceConnected(uuid)` was never called.

Root cause:

- This is not evidence that the device rejected AUTH. In this log shape, AUTH was queued but the business auth drain never started.
- The current demo drain is gated by `_connecting`; if the UI flow has already been stopped by a timeout or stale state while native auto reconnect later emits `connectFinish`, the queue remains pending and no `0x04` write is attempted.

Fix:

- Distinguish "queued but not sent" from "sent but no `authSecAuth=true` callback" in logs.
- When native auto reconnect produces `connectFinish`, re-enter the business connect flow or allow the auth drain to run for the selected cached device instead of requiring the original foreground `_connecting` flag.
- Keep the native timeout as a guard, but ensure it does not stop the business auth phase before the first `AUTHENTICATION` command has actually been sent.

Owner:

- App/example/even_connect owns AUTH queue draining and logical G2 aggregation.
- Native BLE owns only per-peripheral `connectFinish` and timeout reporting.

## G2 demo: one leg reconnects but detail button still shows Reconnect/Disconnect

Symptoms:

- A selected G2 detail page receives native `connectStatus` for one leg such as
  `connecting`, `searchService`, `searchChars`, or `connectFinish`.
- The bottom primary button still shows `Reconnect` or `Disconnect` instead of
  `Connecting`.
- The top detail card shows SN/name/MAC but does not reveal which leg is
  reconnecting, connected, or failed.

Root cause:

- Native auto reconnect can update `_connectStates[uuid]` without starting a
  foreground `_connecting` session.
- The detail button was derived only from `_connecting`, so per-leg native
  reconnect progress was invisible to the action state.
- The top card was built outside the `ValueListenableBuilder` used by logs and
  actions, so it did not repaint when `connectStatus` changed.

Fix:

- Derive the detail action state from `_connecting` or any selected leg whose
  `BleConnectState.isConnecting` is true.
- When the whole-device flow is explicitly stopped, convert stale in-progress
  leg states to a terminal UI state so an old `connectFinish` cannot keep the
  retry button stuck at `Connecting`.
- Rebuild the summary card from the same state notifier that advances logs and
  buttons.
- Show each leg's current `BleConnectState` beside its name and MAC so a
  left/right reconnect split is visible without opening logs.

Owner:

- App/example/even_connect UI aggregation owns this. Native BLE should continue
  to report one peripheral state at a time.

## Android hot restart: native says already connected but Dart restore is stuck

Symptoms:

- Flutter hot restart logs `restore cached device` and starts a direct G2
  reconnect.
- Android native logs `already connected at system GATT` and then
  `device is already connected`.
- Dart never receives a fresh `connectStatus.connected` or `connectFinish` for
  that leg, so the G2 serial restore flow stays on the first leg.
- Notify packets may still arrive from the other leg, proving the native GATT
  session survived the hot restart.

Root cause:

- Flutter hot restart clears Dart memory, including selected leg states and
  whole-device aggregation.
- Android native plugin state can survive hot restart with an existing
  `BleDevice`, `BluetoothGatt`, characteristic cache, and `CONNECTED` state.
- The Android foreground connect path treated `isConnected && myGatt != null`
  as a duplicate request and returned silently after logging. That is correct
  for native resource use but wrong for a fresh Dart runtime that needs the
  current state replayed through EventChannel.

Fix:

- When foreground `connectDevice` hits an already-connected cached GATT, do not
  reopen GATT if Android's system GATT connected list also confirms the device
  is still connected.
- If local cache says connected but the system connected list no longer contains
  the device, treat it as a stale GATT, release it, and reconnect.
- Replay the native cached `BleConnectState` through the normal
  `handleConnectState` path so Dart sees `connected` and can continue
  whole-device aggregation.
- Keep this as native state replay, not a Dart-side guess from log text; only
  native knows whether the current GATT and characteristic cache are still valid.

Owner:

- `flutter_ezw_ble` Android owns replaying native per-peripheral state on
  duplicate foreground connect.
- App/example/even_connect owns the logical G2 aggregation after the replayed
  state arrives.

## Native reconnect review: failures must produce terminal states

Symptoms:

- Dart calls `initConfigs` and immediately starts scan/connect, but iOS still
  behaves as if no config exists.
- `connectDevice` fails native argument decoding or a BLE precondition check,
  while Dart's Future appears successful and the UI remains `Connecting`.
- Android descriptor writes or MTU requests are rejected synchronously by the
  framework, but no later callback arrives to advance or fail the GATT pipeline.
- A stale iOS restoration target references a config name that no longer exists
  and crashes during restore.
- User disconnect/reset/cleanup is followed by an unexpected auto reconnect
  because the persisted reconnect target survived the user action.

Root cause:

- MethodChannel calls are part of the state machine contract. If native returns
  success before the required state is installed, Dart can legally start the
  next operation against stale native state.
- Android BLE APIs can fail both asynchronously and synchronously. When
  `writeDescriptor` or `requestMtu` returns failure, the matching callback may
  never be delivered.
- Persisted reconnect targets represent explicit business intent. They must be
  removed when the user explicitly disconnects, removes, resets, or cleans
  native connection state.
- iOS State Restoration can deliver peripherals after configuration has
  changed. Restoration must validate persisted config names instead of force
  unwrapping them.

Fix:

- Make iOS `initConfigs` update native configuration before returning success
  to Dart. Defer restoration replay inside the manager/coordinator, not by
  delaying the config write itself.
- Return MethodChannel errors for invalid `connectDevice` payloads so callers
  can leave `Connecting` immediately.
- On Android, convert BLE unavailable/config missing/empty uuid/no config into
  explicit `connectStatus` terminal states.
- Treat descriptor callback failure and descriptor enqueue rejection as
  `charsFail`, because private notify readiness is not complete.
- Treat MTU request rejection as a non-fatal default-MTU completion only after
  private services and CCCD are already ready.
- Validate iOS restored targets against current configs and remove stale
  persisted targets instead of crashing.
- Clear persisted reconnect targets on user disconnect, reset, and connection
  cache cleanup.

Owner:

- `flutter_ezw_ble` native owns terminal states for platform/GATT failures.
- App/even_connect owns deciding whether to retry after a terminal state.

## Native reconnect review: delayed owners must be cancellable and identity-safe

Symptoms:

- Android foreground connect enters `Connecting`, starts a scan-refresh delay,
  and later reconnects even if the user has already disconnected, removed the
  device, or started a newer connect request for the same target.
- Android passive auto reconnect logs `connectGatt returned null`, but no later
  retry occurs because the device remains in an in-progress state.
- iOS timeout or request cleanup removes the wrong active connect request when
  multiple peripherals share a display name, or when a temporary/empty uuid was
  used during scan-then-connect.

Root cause:

- A delayed scan-refresh coroutine is still an owner of the connect state
  machine. If it is not keyed and cancellable, it can outlive the user action
  that invalidated it.
- Passive `connectGatt` can fail synchronously before Android posts any GATT
  callback. Emitting `Connecting` and then scheduling backoff directly leaves
  the current `BleDevice` in a flow-connecting state, so the next attempt is
  rejected as duplicate work.
- Names are not stable identities. iOS active requests and timers must prefer a
  real CoreBluetooth UUID; name fallback is only acceptable when one side still
  has a temporary scan identity.

Fix:

- Key Android scan-refresh jobs by reconnect identity, cancel the previous job
  before starting a new one, and guard delayed continuations with a generation
  token.
- Cancel scan-refresh and scan-then-connect owners on explicit
  disconnect/remove/reset cleanup so user intent wins over stale delayed work.
- When passive Android `connectGatt` returns null, route the failure through
  `handleConnectState(.timeout)` so the current flow reaches a terminal state
  before backoff schedules the next attempt.
- On iOS, centralize active request/timer matching in an identity helper: stable
  non-temporary UUIDs must match by UUID only; fallback matching by name is
  allowed only when UUID identity is unavailable.

Owner:

- `flutter_ezw_ble` native owns cancellation and identity safety for delayed
  connect owners.
- App/even_connect should treat repeated `Connecting`/terminal transitions as
  normal per-peripheral events and avoid inferring ownership from display names.

## Native auto reconnect intent must not stop after long absence

Symptoms:

- A device was business connected, auto reconnect was enabled, and then the
  device stayed away for many minutes.
- When the device comes back, no new native reconnect attempt appears.
- Logs may show repeated `timeout`, `noDeviceFound`, passive watchdog refresh,
  or an old `max attempts reached` / `skip attempt` message before reconnect
  activity stops.
- Android R1 may log `passive watchdog refresh`, then `schedule attempt 2`,
  followed by `ignored because state=CONNECTING passiveGatt=false`; after that
  the UI stays connecting forever and no new passive GATT is created.
- A bad acceleration attempt may log `passive watchdog refresh` followed by
  `schedule attempt N after 1000ms`, with repeated Android
  `cancelOpen/close/unregisterApp/registerApp` for G2 left, G2 right, and R1.
  This means the app is destroying the native pending autoConnect handle before
  Android has a stable chance to reconnect.

Root cause:

- Auto reconnect is a long-lived intent created after `deviceConnected(uuid)`,
  not a foreground connect flow with a finite retry count.
- A timeout or `noDeviceFound` only means one attempt failed while the device was
  unavailable. Treating that as a final stop breaks the product expectation that
  a previously connected device can return later.
- Android passive `autoConnect=true` may need periodic zombie-GATT refreshes,
  but the watchdog must only recreate the pending handle, never delete the task.
- A passive refresh timer is itself stored on the reconnect task. If
  `beginAttempt` checks `task.timer == null` before clearing the fired timer,
  the refresh attempt is rejected by its own timer while the visible device
  state is intentionally still `CONNECTING`.
- `autoConnect=true` is itself the native rendezvous point. Treating it like a
  scan loop and recreating it every few seconds resets that rendezvous point and
  can be worse than waiting behind backoff.
- iOS CoreBluetooth pending connect is the system wake/reconnect point; app
  timers or attempt counters must not cancel it while waiting for the peripheral
  to return.

Fix:

- Keep reconnect tasks alive until user/business explicitly calls
  `disconnectDevice`, `removeDevice`, reset/cleanup, disables the config, or the
  process actually dies.
- Do not use `autoReconnectMaxAttempts` as a stop condition. Keep the field only
  for compatibility/backoff diagnostics.
- On Android, keep a live pending passive GATT registered and let the watchdog
  observe/re-arm without emitting a Dart/UI `timeout`; visible state stays
  connecting.
- Do not decouple Android passive refresh by adding a short close/recreate loop.
  A live pending passive GATT should stay registered; the watchdog may observe
  and re-arm itself, and should rebuild only if the passive handle is already
  missing.
- When the scheduled passive refresh attempt fires, clear `task.timer` before
  duplicate-connection guards, and allow `previousState=TIMEOUT +
  state=CONNECTING + passiveGatt=null` to rebuild the passive GATT.
- On iOS, keep native passive reconnect as a CoreBluetooth pending connect. The
  watchdog may log pending status, but it must not emit Dart/UI `timeout`;
  start short timeouts only after `didConnect` enters GATT readiness.

Owner:

- `flutter_ezw_ble` native owns preserving the reconnect intent.
- App/even_connect owns explicit user/business cancellation and post-`connectFinish`
  protocol recovery.

## Example cached config: initConfigs timeout blocks cached reconnect

Symptoms:

- App relaunch logs `initConfigs: TimeoutException after 0:00:05.000000`.
- A little later native logs `BleChannel::initConfigs received=..., decoded=...`.
- The example restores the cached device identity, then logs
  `connectFlow blocked: BLE configs missing`.
- The home page or cached reconnect path appears stuck for a long time after
  adding runtime config caching.

Root cause:

- Dart `Future.timeout` does not cancel the underlying MethodChannel call.
- Treating the timeout as a hard config failure sets `_configsReady=false` even
  though native may still accept the config moments later.
- Cached-device restore then races ahead while the example believes configs are
  missing, so the connect flow is blocked by the UI/business guard instead of
  waiting for the late native acknowledgement.

Fix:

- Treat `initConfigs` timeout as `pending`, not failure.
- Keep the original MethodChannel Future alive; when it completes later, mark
  configs ready and replay cached-device recovery.
- Defer cached-device restore until configs are actually ready.
- Use an epoch/generation guard so a late acknowledgement from an older config
  load cannot mark a newer config set ready.

Owner:

- Example/even_connect owns cached config readiness and cached-device replay.
- Native `flutter_ezw_ble` owns returning `initConfigs` promptly, but Dart must
  remain robust when platform work is delayed by restoration or lifecycle order.

## iOS reinstall: stale peripheral UUID plus ANCS system connection

Symptoms:

- The server restores old iOS peripheral UUIDs after reinstall.
- One G2 leg is rediscovered and migrates to a new UUID, while the ANCS leg never
  advertises and repeatedly logs `no peripheral cache yet`.
- iOS Settings reports both legs connected, but the App never reaches private
  service discovery, CCCD, AUTH, or business `connected` for the missing leg.

Root cause:

- Reinstall invalidates app-scoped CoreBluetooth identifiers.
- ANCS can keep the peripheral system-connected and stop its advertisement.
- The reconnect direct path only checked the stale identifier and scan cache; it
  did not adopt `retrieveConnectedPeripherals(privateServices + ANCS)`.

Fix:

- Query system-connected peripherals before retrieving the stale identifier.
- Match only a stable UUID or an exact non-empty endpoint name; never use prefix
  or empty-name fallback for takeover.
- Migrate reconnect task, aliases, persistent target, and Gate identity before
  registering admission, then continue through the existing single GATT pipeline.
- Do not add a scan, a second connect, or a relaxed callback epoch rule.

Owner:

- Native iOS owns system-connected peripheral takeover and canonical UUID migration.
- even_connect owns persisting the callback UUID into the logical device cache.
- The App owns initializing auto-connect only when authoritative server binding
  exists and the current user namespace has never stored an intent.
