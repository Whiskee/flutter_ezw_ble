import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'iOS commits connected-device state before it releases the admission gate',
      () {
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final updateStart = manager.indexOf('private func updateConnectedDevice(');
    final updateEnd =
        manager.indexOf('private func tryEmitConnectFinish(', updateStart);
    final update = manager.substring(updateStart, updateEnd);

    // .connected 会同步释放 Gate 并可启动下一 endpoint；缓存写回必须先发生，
    // 不能在状态推进后继续以先前 firstIndex 得到的下标写数组。
    final stateUpdate =
        update.indexOf('connectedDevice.isConnected = isConnected');
    final commitBeforeEvent = update.indexOf(
      'connectedDevices[index] = connectedDevice',
      stateUpdate,
    );
    final stateEvent = update.indexOf(
      'handleConnectState(uuid: uuid, name: name, state: reportedState)',
    );

    expect(stateUpdate, greaterThanOrEqualTo(0));
    expect(commitBeforeEvent, greaterThanOrEqualTo(0));
    expect(update, contains('? .connected'));
    expect(stateEvent, greaterThan(commitBeforeEvent));
    expect(
      update.substring(stateEvent),
      isNot(contains('connectedDevices[index] = connectedDevice')),
      reason: '状态上报后不可使用本次 firstIndex 持有的数组下标回写缓存',
    );
  });
}
