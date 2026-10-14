import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS dispatches system-connected peripheral probe', () {
    final source =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();

    expect(source, contains('case isSystemConnectedPeripheral'));
    expect(source, contains('case .isSystemConnectedPeripheral:'));
    expect(source, contains('BleManager.shared.isSystemConnectedPeripheral('));
  });

  test(
      'iOS startScan keeps external service filters separate from internal scans',
      () {
    final channel =
        File('ios/Classes/ble/BleMethodChannel.swift').readAsStringSync();
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final pipeline =
        File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync();
    final reconnect = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();

    expect(channel, contains('iosServiceUuids'));
    expect(channel, contains('BleManager.shared.startExternalScan('));
    expect(channel, contains('BleManager.shared.stopExternalScan()'));
    expect(manager, contains('externalScanServiceUuids'));
    expect(manager, contains('let result = reconcileScanWindow(reason: "externalStart")'));
    expect(manager, contains('clearExternalScanIntent()'));
    expect(manager, contains('externalStartFailed'));
    expect(
      manager,
      contains(
        'UIApplication.shared.applicationState == .active &&\n'
        '            (hasInternalDemand || (externalScanActive && externalScanIncludeUnfilteredScan))',
      ),
    );
    expect(manager,
        contains('withServices: serviceUuids.isEmpty ? nil : serviceUuids'));
    expect(manager, contains('let pureHintUuidStrings = externalScanActive ? externalScanServiceUuids : []'));
    expect(manager, contains('scanPureServiceUuidHints = Set(pureHintUuidStrings)'));
    expect(manager, contains(r'pureHints=\(pureHintSignature)'));
    expect(manager, contains('peerPairingRecoveryScanOwnerKeys'));
    expect(manager, contains('let hasInternalDemand = internalScanActive || !peerPairingRecoveryScanOwnerKeys.isEmpty || startConnectInfos.isNotEmpty'));
    expect(manager, contains('func startPairingRecoveryScanOwner(key: String) -> [String: Any]'));
    expect(manager, contains('func stopPairingRecoveryScanOwner(key: String)'));
    expect(manager, contains('func stopAllPairingRecoveryScanOwners()'));
    expect(reconnect, contains('let scanStart = startPairingRecoveryScanOwner(key: key)'));
    expect(reconnect, contains('let ownsScan = (scanStart["started"] as? Bool) == true'));
    expect(reconnect, contains('stopPairingRecoveryScanOwner(key: key)'));
    expect(reconnect, contains('stopPairingRecoveryScanOwner(key: entry.key)'));
    expect(reconnect, contains('stopAllPairingRecoveryScanOwners()'));
    expect(manager, contains('isSupportedScanServiceUuid'));
    expect(pipeline, contains('pureScanResultTempUuids'));
    expect(pipeline, contains('scanPureModelIncludesNormalResults'));
    expect(pipeline, contains('CBAdvertisementDataServiceUUIDsKey'));
    expect(pipeline, contains('advertisementMatchesServiceUuidHint'));
  });

  test('iOS preserves CDM and PI attempts as automatic reconnect sources', () {
    final model =
        File('ios/Classes/ble/models/BleConnect.swift').readAsStringSync();
    final flow = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();

    expect(model, contains('case androidCdm'));
    expect(model, contains('case androidBlePendingIntent'));
    expect(model, contains('var isAutomaticReconnect: Bool'));
    expect(flow, contains('admission.source.isAutomaticReconnect'));
  });
}
