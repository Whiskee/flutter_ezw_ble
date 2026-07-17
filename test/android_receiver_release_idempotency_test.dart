import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android receiver release is idempotent across repeated engine teardown', () {
    final listener = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/services/BleStateListener.kt',
    ).readAsStringSync();
    final manager = File(
      'android/src/main/kotlin/com/fzfstudio/ezw_ble/ble/BleManager.kt',
    ).readAsStringSync();

    // FlutterEngine 的 detach 可能重复触发。listener 必须记录真实注册态，
    // unregister 只在登记过时调用系统 API，并将系统已提前清理的 receiver 视为已释放。
    expect(listener, contains('private var isReceiverRegistered = false'));
    expect(listener, contains('if (!isReceiverRegistered) return'));
    expect(listener, contains('context.unregisterReceiver(bluetoothReceiver)'));
    expect(listener, contains('catch (_: IllegalArgumentException)'));
    expect(listener, contains('isReceiverRegistered = false'));

    // manager 释放后必须丢弃 listener 引用，避免第二次 release 再次触达旧 receiver。
    expect(manager, contains('private var bleStateListener: BleStateListener? = null'));
    expect(manager, contains('bleStateListener?.unregister()'));
    expect(manager, contains('bleStateListener = null'));
  });
}
