import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('activation API and source-tagged contact event are wired on both hosts',
      () {
    final androidMethod = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final iosMethod =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final iosReconnect =
        File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
            .readAsStringSync();
    final iosFlow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(androidMethod, contains('ACTIVATE_AUTO_RECONNECT_TARGETS'));
    expect(androidMethod, contains('BleConnectSource.fromFlutterValue'));
    expect(androidManager, contains('activateAutoReconnectTargets'));
    expect(androidManager, contains('.put("source", source.flutterValue)'));
    expect(androidManager, contains('.put("generation", legacyGeneration)'));
    expect(androidManager,
        contains('.put("sessionGeneration", legacyGeneration)'));
    expect(androidManager,
        contains('.put("attemptGeneration", attemptGeneration)'));
    expect(iosMethod, contains('activateAutoReconnectTargets'));
    expect(iosMethod, contains('BleConnectSource(rawValue:'));
    expect(iosReconnect, contains('activateAutoReconnectTargets'));
    expect(iosFlow, contains('source: source'));
    expect(iosManager, contains('generation: eventGeneration'));
    expect(iosManager, contains('attemptGeneration: eventAttemptGeneration'));
  });

  test('native reconnect status separates session and attempt generations', () {
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final androidSupervisor = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final iosConnect =
        File('ios/Classes/ble/models/BleConnect.swift').readAsStringSync();

    expect(
        androidManager,
        contains(
            'autoReconnectSupervisor.activate(seedDevice, source, sessionGeneration)'));
    expect(
        androidManager,
        contains(
            'sessionGeneration = if (sessionGeneration > 0L) sessionGeneration else generation'));
    expect(
        androidSupervisor,
        contains(
            'createConnectCallback(task.uuid, task.source, task.sessionGeneration)'));
    expect(iosConnect, contains('case sessionGeneration'));
    expect(
        iosConnect,
        contains(
            'try container.encode(sessionGeneration, forKey: .generation)'));
    expect(iosConnect, contains('case attemptGeneration'));
  });

  test(
      'higher reconnect session rebuilds the exact physical owner on both hosts',
      () {
    final androidModels = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleReconnectModels.kt',
    ).readAsStringSync();
    final androidSupervisor = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final iosReconnect =
        File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
            .readAsStringSync();

    // Android 不能把旧 GATT callback 动态重标成新 session；更高 session
    // 必须走 exact teardown，并且 activation ack 只能回报实际安装值。
    expect(
      androidModels,
      contains('REBUILD_PHYSICAL_OWNER'),
    );
    expect(
      androidSupervisor,
      contains(
        'invalidatePassiveGattForSessionRebind(device.uuid, exactGatt)',
      ),
    );
    expect(
      androidSupervisor,
      contains(
        'createConnectCallback(task.uuid, task.source, task.sessionGeneration)',
      ),
    );
    expect(androidManager, contains('reason = if (requestedSessionInstalled)'));
    expect(androidManager, contains('"sessionNotInstalled"'));
    expect(
      androidManager,
      contains('sessionGeneration = installedSessionGeneration'),
    );

    // iOS 同样先登记 cancellation barrier，再让 replacement admission
    // 携带新 session；同 session 的 manual promotion 不进入这条路径。
    expect(
      iosReconnect,
      contains(
        'if task.sessionGeneration > current.sessionGeneration',
      ),
    );
    expect(
      iosReconnect,
      contains('deferConnectionAdmissionReleaseUntilPeripheralTerminal'),
    );
    expect(
      iosReconnect,
      contains('beginReconnectAttempt(uuid: task.uuid)'),
    );
  });

  test('iOS name-only activation owns identity before normal MAC filtering',
      () {
    final method =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final scan =
        File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync();

    expect(method, contains('expectedMacSuffix:'));
    expect(method, contains('result(acknowledgements.map(\\.raw))'));
    expect(reconnect, contains('BlePendingReconnectIdentity'));
    expect(reconnect, contains('state: .identityPending'));
    expect(reconnect, contains('resolvePendingReconnectIdentity'));
    expect(manager, contains('pendingReconnectIdentities'));
    expect(
      scan.indexOf('resolvePendingReconnectIdentity'),
      lessThan(scan.indexOf('guard deviceMac.isNotEmpty')),
    );
  });

  test('Android starts GATT readiness only after global gate grant', () {
    final callback = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final reconnect = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();

    expect(callback, contains('onPhysicalConnected'));
    expect(callback, isNot(contains('gatt.discoverServices()')));
    expect(manager, contains('connectionAdmissionGate.onPhysicalConnected'));
    expect(manager, contains('startGrantedGattPipeline'));
    expect(manager, contains('releaseAdmissionAndStartNext'));
    expect(manager, contains('completeBusinessConnectionAdmission'));
    expect(reconnect, isNot(contains('BleConnectState.CONNECTING')));
  });

  test('Android R1 bonds inside the gate before GATT readiness', () {
    final callback = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final listener = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/services/BleStateListener.kt',
    ).readAsStringSync();

    expect(callback, isNot(contains('createBond()')));
    expect(manager, contains('startBondBeforeGattReadiness(current, session)'));
    expect(manager, contains('session.gatt.device.createBond()'));
    expect(manager, contains('connectionAdmissionGate.isActive(current)'));
    expect(manager, contains('startGrantedServiceDiscovery'));
    expect(manager, contains('state = BleConnectState.BOUND_FAIL'));
    expect(listener, contains('BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE'));
    expect(
        listener, isNot(contains('bondState == BluetoothDevice.BOND_BONDING')));
  });

  test(
      'Android business-connected GATT disconnect survives admission release and restarts passive reconnect',
      () {
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final callback = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleGattSessionCallback.kt',
    ).readAsStringSync();
    final reconnect = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();

    expect(
        callback,
        contains(
            'onSessionTerminal(gatt, BleConnectState.DISCONNECT_FROM_SYS'));
    expect(manager, contains('BlePostAdmissionTerminalPolicy.resolve'));
    expect(manager, contains('businessConnectedGattSessions'));
    expect(manager, contains('session.gatt === gatt'));
    expect(
      manager,
      contains('session.admission.sessionId == expectedAdmission.sessionId'),
    );
    expect(
      manager,
      contains(
          'BlePostAdmissionTerminalDisposition.BUSINESS_CONNECTED_SESSION'),
    );
    expect(manager, contains('source = expectedAdmission.source'));
    expect(
        manager, contains('generation = expectedAdmission.sessionGeneration'));
    expect(
        manager, contains('attemptGeneration = expectedAdmission.generation'));
    expect(manager, contains('autoReconnectSupervisor.schedule(uuid, state)'));
    expect(reconnect, contains('task.passiveGatt = null'));
    expect(
      reconnect,
      contains(
        'task.timer = attemptDispatcher.dispatch(task.uuid, delayMs, scheduleGeneration)',
      ),
    );
  });

  test('iOS didConnect, already-connected and restoration all enter one gate',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final restoration = File('ios/Classes/ble/BleStateRestorationFlow.swift')
        .readAsStringSync();
    final reconnect = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(flow, contains('connectionAdmissionGate.onPhysicalConnected'));
    expect(flow, contains('startGrantedGattPipeline'));
    expect(flow, contains('completeBusinessConnectionAdmission'));
    expect(restoration, contains('escrowStateRestorationPeripheral'));
    expect(reconnect, contains('activateClaimedStateRestoration'));
    expect(reconnect, contains('enqueuePhysicalConnectionThroughGate'));
    expect(manager, contains('willRestoreState'));
  });

  test(
      'iOS auto reconnect watchdog observes the long-lived system request without recycling it',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(manager, contains('pendingPhysicalConnectWatchdogs'));
    expect(flow, contains('startPendingPhysicalConnectWatchdog'));
    expect(flow, contains('BlePendingPhysicalConnectWatchdogMode.resolve'));
    expect(flow, contains('currentConnectionAdmission(expectedAdmission)'));
    expect(
      flow,
      contains(
        'auto reconnect pending beyond watchdog; keep CoreBluetooth request',
      ),
    );
    expect(
      flow,
      contains('case .observeLongLivedAutoReconnect:'),
      reason: 'autoReconnect 的 watchdog 只能观察，不能每分钟重置系统 pending connect',
    );
    expect(
      flow,
      contains('case .recycleForegroundAttempt:'),
      reason: '普通前台连接仍需在一分钟后有界清理，避免 admission 永久占用',
    );
  });

  test('manual pending connect is promoted without cancelling long-lived task',
      () {
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final iosConnect =
        File('ios/Classes/ble/BleConnectCoordinator.swift').readAsStringSync();
    final iosFlow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(androidManager, contains('promotePendingAttempt'));
    expect(
      androidManager,
      isNot(contains(r'reason = "foreground connect ${request.belongConfig}"')),
    );
    expect(iosConnect, contains('promotePendingAttempt'));
    expect(iosFlow, contains('source: .manualReconnect'));
    expect(
      iosManager,
      isNot(contains('autoReconnectCoordinator.cancel(uuid: request.uuid')),
    );
  });

  test('iOS manual handoff only replaces a stale no-contact pending request',
      () {
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();
    final gate = File('ios/Classes/ble/BleConnectionAdmissionGate.swift')
        .readAsStringSync();
    final connect =
        File('ios/Classes/ble/BleConnectCoordinator.swift').readAsStringSync();

    // 20 秒是恢复 batch 的单次辅助扫描预算：阈值内的手动点击仍只是 promote，
    // 防止用户连续点击把正常的 CoreBluetooth pending connect 反复重置。
    expect(flow,
        contains('manualPendingReplacementThreshold: TimeInterval { 20.0 }'));
    expect(flow, contains('!session.hasObservedPhysicalContact'));
    expect(flow, contains('elapsed >= manualPendingReplacementThreshold'));
    expect(flow, contains('!hasPeripheralCancellationBarrier(peripheral)'));
    expect(flow,
        contains('deferConnectionAdmissionReleaseUntilPeripheralTerminal('));
    expect(flow,
        contains('centralManager.cancelPeripheralConnection(peripheral)'));
    expect(flow, contains('manual stale pending replacement'));
    expect(gate, contains('let pendingConnectStartedAt: Date'));
    expect(gate, contains('var hasObservedPhysicalContact: Bool = false'));
    expect(reconnect, contains('replaceStalePendingManualAttemptIfNeeded'));
    expect(reconnect, contains('beginReconnectAttempt(uuid: task.uuid)'));
    expect(connect, contains('replaceStalePendingManualAttemptIfNeeded'));
    expect(connect, contains('replace stale pending autoReconnect attempt'));
  });

  test('iOS visible auto reconnect target repairs only the exact stale owner',
      () {
    final method =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();
    final gate = File('ios/Classes/ble/BleConnectionAdmissionGate.swift')
        .readAsStringSync();
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();

    expect(method, contains('reconcileVisibleAutoReconnectTarget'));
    expect(method, isNot(contains('result(false)\n            return')));
    expect(manager, contains('visiblePendingRecoveryWatchdogs'));
    expect(gate, contains('BleVisiblePendingRecoveryWatchdogRegistry'));
    expect(flow, contains('scheduleVisiblePendingRecovery'));
    expect(flow, contains('currentConnectionAdmission(expectedAdmission)'));
    expect(flow, contains('!session.hasObservedPhysicalContact'));
    expect(flow, contains('replaceStalePendingAttemptIfNeeded'));
    expect(flow, contains('trigger: .visibleAutoReconnect'));
    expect(flow, contains('enqueuePhysicalConnectionThroughGate(peripheral)'));
    expect(reconnect, contains('currentIsPendingTeardown'));
    expect(flow, contains('beginReconnectAttempt(uuid: admission.endpointId)'));
  });

  test(
      'connectFinish keeps the auth watchdog until business connected on both hosts',
      () {
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    // connectFinish 只完成 GATT 准备，协议鉴权成功前必须保留 watchdog，
    // 防止 Dart 鉴权链路挂起时永久占住全局连接 Gate。
    expect(
      androidManager,
      contains('CONNECT_FINISH 只表示 BLE 服务/特征流程完成'),
    );
    expect(
      androidManager,
      contains('所以这里不取消超时定时器'),
    );
    expect(androidManager, contains('if (state.isFlowConnecting)'));
    expect(androidManager, contains('连接成功后清理当前设备上的超时定时器'));
    expect(iosManager, contains('超时定时器保留运行，作为协议层鉴权的安全兜底'));
    expect(iosManager, contains('guard !state.isConnecting() else'));
    expect(
      iosManager,
      contains('}), !state.isConnecting() {'),
    );
  });

  test('iOS terminal teardown holds the gate until callback or exact watchdog',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(
      manager,
      contains('deferConnectionAdmissionReleaseUntilPeripheralTerminal'),
    );
    expect(manager, contains('!deferredAdmissionTeardown'));
    expect(flow, contains('peripheralCancellationBarrierTimeout'));
    expect(flow, contains('completePendingConnectionAdmissionTeardown'));
    expect(flow, contains('peripheralCancellationBarrierGate.timeout'));
    expect(
      flow.indexOf('completePendingConnectionAdmissionTeardown('),
      lessThan(flow.indexOf('startDeferredPeripheralConnection(peripheral)')),
    );
  });

  test('iOS terminal reconnect is scheduled only after active owner cleanup',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final handleStateStart = manager.indexOf('func handleConnectState(');
    final handleStateEnd = manager.indexOf(
      'private func getDeviceMTU',
      handleStateStart,
    );
    final handleState = manager.substring(handleStateStart, handleStateEnd);

    // 普通 disconnected/error 终态必须先释放 request owner，再调度下一代；
    // 否则 scheduleReconnect 会看到旧 active request 而永久 defer。
    expect(
      handleState.indexOf('removeActiveConnectRequest(uuid: uuid, name: name)'),
      lessThan(
        handleState.indexOf(
          'scheduleReconnect(uuid: uuid, name: name, state: state)',
        ),
      ),
    );

    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();
    final teardownStart = flow.indexOf(
      'func completePendingConnectionAdmissionTeardown(',
    );
    final teardownEnd = flow.indexOf(
      'private func startDeferredPeripheralConnection(',
      teardownStart,
    );
    final teardown = flow.substring(teardownStart, teardownEnd);

    // cancel callback/watchdog 释放旧 pending owner 时也必须遵守同一顺序。
    // 否则 scheduleReconnect 会看到旧 active request 后选择 defer，而 teardown
    // 随后又删掉旧 admission，最终形成没有任何 CoreBluetooth owner 的死区。
    final pendingOwnerCleanup = teardown.indexOf('removeActiveConnectRequest(');
    expect(teardown, contains('uuid: pending.admission.endpointId'));
    final pendingReconnectSchedule = teardown.indexOf('scheduleReconnect(');
    expect(pendingOwnerCleanup, isNonNegative);
    expect(pendingReconnectSchedule, isNonNegative);
    expect(pendingOwnerCleanup, lessThan(pendingReconnectSchedule));
  });

  test('iOS stale business cache cannot suppress a pending auto reconnect', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnect = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    // 断连时必须失效同 UUID 的所有缓存；回连只可相信 CoreBluetooth 仍处于 connected
    // 的业务缓存，防止陈旧 isConnected=true 跳过 system pending connect。
    expect(manager, contains('let cacheIndexes = connectionCacheIndexes'));
    expect(manager, contains('for index in cacheIndexes'));
    expect(
        reconnect, contains('businessConnectedCacheDevice(uuid: task.uuid)'));
    expect(reconnect, contains('replaceConnectionCache('));
    expect(flow, contains('peripheral.state == .connected'));
    expect(flow, contains('staleBusinessConnected'));
    expect(flow, contains('retrieve 或 restoration'));
  });

  test('iOS bluetooth-off terminals preserve an epoch-accepted generation', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnectStore =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();
    final reconnectCoordinator = File(
      'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
    ).readAsStringSync();

    expect(reconnectStore, contains('lastConnectedGeneration'));
    expect(reconnectStore, contains('lastConnectedAttemptGeneration'));
    expect(
      reconnectCoordinator,
      contains('task.lastConnectedGeneration = generation'),
    );
    expect(
      reconnectCoordinator,
      contains('task.lastConnectedAttemptGeneration = attemptGeneration'),
    );
    expect(
      reconnectCoordinator,
      contains(
        'let generation = admission?.sessionGeneration ?? task?.lastConnectedGeneration',
      ),
    );
    expect(
      reconnectCoordinator,
      contains(
        'let attemptGeneration = admission?.generation ?? task?.lastConnectedAttemptGeneration',
      ),
    );
    expect(reconnectCoordinator, contains('capturedEndpointKeys.insert(key)'));
    expect(manager, contains('let transportOffSnapshots ='));
    expect(
      manager.indexOf('let transportOffSnapshots ='),
      lessThan(
          manager.indexOf('suspendConnectionAdmissionGateForBluetoothOff()')),
    );
    expect(manager, contains('source: snapshot.source'));
    expect(manager, contains('generation: snapshot.generation'));
    expect(manager,
        contains('attemptGeneration: snapshot.attemptGeneration'));
  });

  test('Android bluetooth-off terminals preserve an epoch-accepted generation',
      () {
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final policy = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleBluetoothOffTerminalMetadataPolicy.kt',
    ).readAsStringSync();
    final setConnectedStart = manager.indexOf('fun setConnected(uuid: String)');
    final setConnectedEnd =
        manager.indexOf('fun disconnect(', setConnectedStart);
    final setConnected = manager.substring(setConnectedStart, setConnectedEnd);

    // 业务 connected 只接受有 source/generation 的 admission，因此 transport-off
    // 在 Gate release 前后都能从 current 或 business-connected session 取到同代终态。
    expect(policy, contains('currentAdmission.takeIf(::isEpochAccepted)'));
    expect(policy,
        contains('businessConnectedAdmission.takeIf(::isEpochAccepted)'));
    expect(policy, contains('admission.source != BleConnectSource.UNKNOWN'));
    expect(policy, contains('admission.sessionGeneration > 0L'));
    // Kotlin 明确绑定通过校验的非空 admission，避免依赖 policy 调用后的 smart-cast。
    expect(setConnected, contains('isEpochAccepted(acceptedAdmission)'));
    expect(setConnected, contains('source = acceptedAdmission.source'));
    expect(setConnected,
        contains('generation = acceptedAdmission.sessionGeneration'));
    expect(setConnected,
        contains('attemptGeneration = acceptedAdmission.generation'));
    expect(setConnected, isNot(contains('BleConnectSource.UNKNOWN')));

    expect(manager, contains('val transportOffCapture ='));
    expect(
      manager.indexOf('val transportOffCapture ='),
      lessThan(manager.indexOf('connectionAdmissionGate.suspendAndReset()')),
    );
    expect(
        manager,
        contains(
            'businessConnectedAdmission = businessConnectedGattSessions[key]?.admission'));
    expect(manager, contains('source = snapshot.source'));
    expect(manager, contains('generation = snapshot.sessionGeneration'));
    expect(manager, contains('attemptGeneration = snapshot.attemptGeneration'));
    // BroadcastReceiver 不能用诊断断言杀进程；无 admission 时仅可复用有效 owner，
    // 否则隔离并释放缓存，同时 power-cycle 与其它复合状态写共享 Manager monitor。
    expect(manager, isNot(contains('checkNotNull(')));
    expect(manager, contains('resolveReconnectOwnerTerminalMetadata'));
    expect(manager, contains('quarantinedDevices'));
    expect(manager, contains('@Synchronized\n    private fun handleBluetoothStateChanged'));
    expect(manager, contains('handleBluetoothStateChanged(state)'));
  });

  test('upgrade state cannot manufacture or resurrect a connected endpoint',
      () {
    final androidManager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final androidPolicy = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleBluetoothOffTerminalMetadataPolicy.kt',
    ).readAsStringSync();
    final iosManager =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    expect(androidPolicy, contains('internal object BleUpgradeStatePolicy'));
    expect(androidManager, contains('BleUpgradeStatePolicy.canEnter'));
    expect(androidManager, contains('BleUpgradeStatePolicy.canExitToConnected'));
    expect(androidManager, contains('if (!upgradeDevices.remove(uuid))'));
    expect(androidManager, contains('source = acceptedAdmission.source'));
    expect(androidManager,
        contains('generation = acceptedAdmission.sessionGeneration'));
    expect(iosManager, contains('connectedDevice.isConnected'));
    expect(iosManager, contains('connectedDevice.peripheral.state == .connected'));
    expect(iosManager, contains('let metadata = metadata else'));
    expect(iosManager,
        contains('generation: metadata.sessionGeneration'));
    expect(iosManager, contains('attemptGeneration: metadata.attemptGeneration'));
  });

  test('iOS live system disconnect reuses the exact business-connected owner',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnectStore =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();

    expect(
      reconnectStore,
      contains('enum BleTerminalConnectionMetadataPolicy'),
    );
    expect(reconnectStore, contains('state == .disconnectFromSys'));
    expect(reconnectStore, contains('task.lastConnectedGeneration'));
    expect(reconnectStore,
        contains('task.lastConnectedAttemptGeneration'));
    expect(
      manager,
      contains('BleTerminalConnectionMetadataPolicy.resolve'),
    );
    expect(
      manager,
      isNot(
          contains('isBusinessConnected: currentDevice?.isConnected == true')),
    );
    expect(
      manager,
      contains('source ?? terminalMetadata?.source ?? .unknown'),
    );
    expect(
      manager,
      contains('generation ?? terminalMetadata?.generation ?? 0'),
    );
    expect(
      manager,
      contains('attemptGeneration ?? terminalMetadata?.attemptGeneration'),
    );
  });

  test('iOS explicit cancellation freezes metadata before removing owners', () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final reconnectStore =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();
    final cancelMethodStart =
        manager.indexOf('func cancelAutoReconnectTargets(');
    final cancelMethodEnd =
        manager.indexOf('func disconnectForOtaReboot(', cancelMethodStart);
    final cancelMethod = manager.substring(cancelMethodStart, cancelMethodEnd);

    expect(
      reconnectStore,
      contains('enum BleExplicitCancellationMetadataPolicy'),
    );
    expect(
      reconnectStore,
      contains('attemptGeneration: admission.generation'),
    );
    expect(
      cancelMethod,
      contains('let cancellationTargets = targets.map'),
    );
    expect(
      cancelMethod.indexOf('let cancellationTargets = targets.map'),
      lessThan(cancelMethod.indexOf(
        'let next = connectionAdmissionGate.cancelEndpoints(endpointIds)',
      )),
    );
    expect(
      manager,
      contains('attemptGeneration: cancellationMetadata?.attemptGeneration'),
    );
    expect(
      manager,
      contains(
        'let eventAttemptGeneration = attemptGeneration ?? terminalMetadata?.attemptGeneration ?? currentAdmission?.generation ?? 0',
      ),
    );
  });

  test('iOS timed-out cancellation debt cannot hide a live system disconnect',
      () {
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(flow, contains('BleTimedOutCancellationDebtPolicy.action'));
    expect(flow, contains('case .handleCurrentDisconnect:'));
    expect(flow, contains('return false'));
    expect(flow, contains('case .redriveCurrentAttempt:'));
    expect(flow, contains('redriveCurrentConnectionAfterCancellationDebt'));
  });

  test('iOS scan-then-connect enters the shared admission gate', () {
    final scan =
        File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync();
    final methodStart = scan.indexOf('private func connectFoundPeripheral(');
    final methodEnd = scan.indexOf(
      'private func sendMatchDevices(',
      methodStart,
    );
    final method = scan.substring(methodStart, methodEnd);

    expect(method, contains('registerConnectionAttempt('));
    expect(method, contains('afterUpgrade: request.afterUpgrade'));
    expect(method, contains('source: .foreground'));
    expect(method, contains('connectPeripheralAfterCancellationBarrier('));
    expect(
      method.indexOf('registerConnectionAttempt('),
      lessThan(method.indexOf('connectPeripheralAfterCancellationBarrier(')),
    );
    expect(method, isNot(contains('startConnectingCountdown(')));
    expect(method, isNot(contains('\n        connectPeripheral(')));
  });
}
