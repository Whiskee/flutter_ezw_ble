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
    // UIScene 下 launchOptions 恒为 nil，必须同时认 willRestoreState 的进程级事实。
    expect(gate, contains('FlutterEzwBlePlugin.wasLaunchedForBluetoothStateRestoration()'));
    expect(gate, contains('|| BleManager.didExperienceStateRestorationThisProcess'));
    // iOS 18 可能只经 connection event 拉起而不回调 willRestoreState（2026-09-09 WK15），
    // 启动瞬间 applicationState == .background 是第三种进程级证据。
    expect(gate, contains('|| launchedHeadless'));
    expect(gate, contains('FlutterEzwBlePlugin.wasLaunchedHeadlessInBackground()'));
    expect(gate, contains('headlessLaunch=\\(launchedHeadless)'));
    final plugin = File('ios/Classes/FlutterEzwBlePlugin.swift').readAsStringSync();
    final capture = plugin.substring(
      plugin.indexOf('public static func captureBluetoothStateRestorationLaunchOptions('),
      plugin.indexOf('public static func register(with registrar: FlutterPluginRegistrar)'),
    );
    // 后台拉起证据必须在 bluetoothCentrals 守卫之前锁存，否则 launchOptions 为 nil 时永远拿不到。
    final latch = capture.indexOf('launchedHeadlessInBackground = true');
    final centralsGuard = capture.indexOf('guard centralIdentifiers.contains(');
    expect(latch, greaterThan(0));
    expect(centralsGuard, greaterThan(latch));
    expect(capture, contains('UIApplication.shared.applicationState == .background'));
    // escrow rearm 标签跟随真实来源，不得把 connectionEvent 写成 willRestoreState。
    final flow = File('ios/Classes/ble/BleStateRestorationFlow.swift').readAsStringSync();
    expect(flow, contains('reason: "\\(source) disconnected"'));
    expect(flow, isNot(contains('reason: "willRestoreState disconnected"')));
    expect(gate, contains('launchedForRestoration,'));
    expect(gate, contains('!hasReceivedWillTerminate,'));
    // UIScene 冷拉起时 applicationState 可能已从 .background 变成 .inactive（2026-09-09
    // WK15 两次重启门禁未放行），补查只要求非 active。
    expect(gate, contains('applicationState != .active,'));
    // 守卫行不得再要求 == .background（注释里可以引用该字面量说明证据来源）。
    expect(gate, isNot(contains('applicationState == .background,')));
    // 拒绝时每进程每 endpoint 记一次条件快照，沙盒日志据此指认具体条件。
    expect(gate, contains('stateRestorationLaunchRetrieveDenialsLogged.insert(key).inserted'));
    expect(gate, contains('state restoration launch retrieve denied uuid='));
    expect(gate, contains('centralManager.state == .poweredOn,'));
    expect(gate, contains('let key = reconnectKey(uuid: endpointId)'));
    expect(gate, contains('return !stateRestorationLaunchRetrieveAttempts.contains(key)'));
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
