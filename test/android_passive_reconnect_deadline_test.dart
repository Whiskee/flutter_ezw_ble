import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android passive deadline only recycles pre-physical exact GATT', () {
    final reconnect = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleAutoReconnectSupervisor.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();
    final task = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleReconnectModels.kt',
    ).readAsStringSync();
    final dispatcher = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleReconnectAttemptDispatcher.kt',
    ).readAsStringSync();
    final androidChannel = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleMethodChannel.kt',
    ).readAsStringSync();
    final iosChannel =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();

    expect(task, contains('pendingPhysicalDeadline'));
    expect(task, contains('passiveStartedAtMs'));
    expect(
        reconnect, contains('coerceAtLeast(MIN_PENDING_PHYSICAL_DEADLINE_MS)'));
    expect(reconnect, contains('fun onPassivePhysicalConnected'));
    expect(reconnect, contains('task.passiveGatt !== expectedGatt'));
    expect(reconnect, contains('retryDelayOverrideMs = retryDelayMs'));
    expect(task, contains('consecutivePrePhysicalTimeouts'));
    expect(task, contains('timeoutCount <= 3 -> 1500L'));
    expect(task, contains('timeoutCount <= 10 -> 5000L'));
    expect(task, contains('else -> 30000L'));
    expect(reconnect, contains('fun notifyTargetVisible'));
    expect(reconnect, contains('hasPrePhysicalGatt'));
    expect(reconnect, contains('hasPendingRetry'));
    expect(reconnect, contains('prepareTargetVisibleDirectConnect'));
    expect(reconnect, contains('scheduleTargetVisibleDirectConnect'));
    expect(reconnect, contains('beginVisibleDirectReconnect'));
    expect(reconnect, contains('acquireVisibleDirectConnectSlot'));
    expect(reconnect, contains('releaseVisibleDirectConnectSlot'));
    expect(reconnect, contains('visibleDirectConnectQueue'));
    expect(reconnect, contains('activeVisibleDirectConnectUuid'));
    expect(task, contains('visibleDirectConnectRequested'));
    expect(task, contains('pendingVisibleDirectConnect'));
    expect(dispatcher, contains('AndroidBleVisibleDirectGattFactory'));
    expect(dispatcher, contains('AndroidBleGattConnector.connect'));
    expect(dispatcher, contains('autoConnect = false'));
    expect(reconnect, contains('task.retryScheduleGeneration'));
    expect(reconnect, contains('visibilityWakeEligible = true'));
    expect(
      reconnect,
      contains(
        'task.pendingPassiveRetry = delayMs > 0L && visibilityWakeEligible',
      ),
    );
    expect(
      reconnect,
      isNot(contains('@Synchronized\n    fun notifyTargetVisible')),
    );
    expect(androidChannel, contains('NOTIFY_AUTO_RECONNECT_TARGET_VISIBLE'));
    expect(iosChannel, contains('case .notifyAutoReconnectTargetVisible:'));
    expect(iosChannel, contains('reconcileVisibleAutoReconnectTarget'));
    expect(
      reconnect,
      isNot(
        contains(
            'handleConnectState(task.uuid, task.name, BleConnectState.TIMEOUT)'),
      ),
    );
    expect(manager,
        contains('autoReconnectSupervisor.onPassivePhysicalConnected'));
    expect(manager, contains('fun invalidatePendingPassiveGatt'));
    expect(manager,
        contains('admittedGattSessions[admission.sessionId]?.gatt === gatt'));
  });
}
