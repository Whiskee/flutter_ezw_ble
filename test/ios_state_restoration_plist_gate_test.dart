import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Locks the iOS State Restoration startup contract in source-level tests.
///
/// The native crash happens before Flutter can catch an exception, so these
/// tests guard the Swift initialization path and example plist declaration
/// directly instead of trying to reproduce CoreBluetooth in a Dart test.
void main() {
  test('iOS state restoration restore identifier is gated by Info.plist', () {
    final managerSource =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();

    // Verify that the restore identifier path is explicitly tied to the host
    // app's bluetooth-central background mode declaration.
    expect(managerSource, contains('bluetoothCentralBackgroundMode'));
    expect(managerSource, contains('canEnableStateRestoration'));
    expect(
      managerSource,
      contains('Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")'),
    );
    expect(
      managerSource,
      contains(
          'CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier'),
    );
    expect(
      managerSource,
      contains(
          'stateRestoration: WARNING disabled because host Info.plist is missing UIBackgroundModes bluetooth-central'),
    );
    expect(
      managerSource,
      contains(
          'add UIBackgroundModes -> bluetooth-central to Runner/Info.plist'),
    );

    // Verify the initializer uses the guarded options value instead of
    // hardcoding CBCentralManagerOptionRestoreIdentifierKey at construction.
    final initBlock = managerSource.substring(
      managerSource.indexOf('private override init()'),
      managerSource.indexOf('NotificationCenter.default.addObserver('),
    );
    expect(initBlock,
        contains('let options = BleManager.centralManagerOptions()'));
    expect(initBlock, contains('options: options'));
    expect(
      initBlock,
      isNot(
        contains(
          'CBCentralManagerOptionRestoreIdentifierKey: BleManager.restorationIdentifier',
        ),
      ),
    );
  });

  test('plugin example declares bluetooth-central for restoration tests', () {
    final plist = File('example/ios/Runner/Info.plist').readAsStringSync();

    // The bundled plugin example should exercise the full State Restoration
    // path, so its Info.plist must keep the required iOS background mode.
    expect(plist, contains('<key>UIBackgroundModes</key>'));
    expect(plist, contains('<string>bluetooth-central</string>'));
  });
}
