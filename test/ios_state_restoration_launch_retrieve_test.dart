import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-07 真机：连接眼镜 B 后关机重启，iOS 只随 willRestoreState 交还右腿；
/// 左腿既无 escrow 也无进程内对象，inactive 门禁下 `beginReconnectAttempt` 直接
/// 延后，headless 10 分钟内从未建立 pending connect，直到用户打开 App 才回连。
/// 以下契约固定「SR 后台拉起窗口内每 endpoint 一次 identifier 补查」。
void main() {
  final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
  final coordinator = File(
    'ios/Classes/ble/BleAutoReconnectCoordinator.swift',
  ).readAsStringSync();

  test('SR launch retrieve is gated to background, poweredOn, not terminating, once per endpoint', () {
    expect(manager, contains('var hasReceivedWillTerminate = false'));
    expect(
      manager,
      contains('var stateRestorationLaunchRetrieveAttempts: Set<String> = []'),
    );
    final gate = manager.substring(
      manager.indexOf('func canAttemptStateRestorationLaunchRetrieve(endpointId: String) -> Bool'),
      manager.indexOf('func retrievePeripheralForStateRestorationLaunch('),
    );
    expect(gate, contains('guard !allowsSynchronousCoreBluetoothLookup,'));
    expect(gate, contains('FlutterEzwBlePlugin.wasLaunchedForBluetoothStateRestoration(),'));
    expect(gate, contains('!hasReceivedWillTerminate,'));
    expect(gate, contains('UIApplication.shared.applicationState == .background,'));
    expect(gate, contains('centralManager.state == .poweredOn,'));
    expect(
      gate,
      contains('return !stateRestorationLaunchRetrieveAttempts.contains(reconnectKey(uuid: endpointId))'),
    );
    final retrieve = manager.substring(
      manager.indexOf('func retrievePeripheralForStateRestorationLaunch('),
    );
    expect(retrieve, contains('stateRestorationLaunchRetrieveAttempts.insert(reconnectKey(uuid: endpointId))'));
    expect(retrieve, contains('centralManager.retrievePeripherals(withIdentifiers: [identifier]).first'));
    expect(retrieve, contains('type: "ios_sr_launch_retrieve"'));
    // 活跃窗口的普通 retrieve 门禁保持不变。
    expect(
      manager,
      contains('''        guard allowsSynchronousCoreBluetoothLookup else {
            loggerD(msg: "appLifecycle: defer retrievePeripherals context=\\(context)")
            return []
        }'''),
    );
  });

  test('willTerminate latches the flag and inactive defer honors the launch retrieve', () {
    final terminate = coordinator.substring(
      coordinator.indexOf('@objc func handleAppWillTerminate()'),
      coordinator.indexOf('@objc func handleAppDidBecomeActive()'),
    );
    expect(terminate, contains('hasReceivedWillTerminate = true'));
    final defer = coordinator.substring(
      coordinator.indexOf('private func shouldDeferReconnectForAppInactivity('),
      coordinator.indexOf('private func deferReconnectTaskForAppInactivity('),
    );
    expect(defer, contains('inMemoryReconnectPeripheral(task) == nil else'));
    expect(
      defer,
      contains('return !canAttemptStateRestorationLaunchRetrieve(endpointId: task.uuid)'),
    );
  });

  test('direct reconnect uses the launch retrieve after in-memory reuse and before active-only lookups', () {
    final direct = coordinator.substring(
      coordinator.indexOf('func beginDirectReconnectAttempt('),
    );
    final reuse = direct.indexOf('reuse in-memory peripheral while inactive');
    final launch = direct.indexOf('retrievePeripheralForStateRestorationLaunch(');
    final systemConnected = direct.indexOf('findPeripheralFromConnected(');
    expect(reuse, isNonNegative);
    expect(launch, greaterThan(reuse));
    expect(systemConnected, greaterThan(launch));
    expect(direct, contains('context: "auto reconnect by UUID during SR launch"'));
  });
}
