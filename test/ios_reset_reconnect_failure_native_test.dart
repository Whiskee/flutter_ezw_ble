import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'production reset and Code 1 policy survives hostile fake-clock timelines',
      () async {
    final directory = await Directory.systemTemp.createTemp('ble-reset-test-');
    addTearDown(() => directory.delete(recursive: true));
    final executable = '${directory.path}/reset-test';
    final compile = await Process.run('swiftc', [
      'ios/Classes/ble/BleReconnectFailurePolicy.swift',
      'test/native/reset_reconnect_failure_test.swift',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, contains('owner/session/epoch/token'));
    expect(run.stdout, contains('ordinary off/on'));
  }, skip: !Platform.isMacOS);

  test('production scheduler executes exact retries against fake platform time',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ble-manager-retry-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    // Compile the production method bodies unchanged. Only platform clock/timer
    // and the downstream physical dispatch boundary are replaced by spies.
    final methods = <String>[];
    for (final marker in [
      'func scheduleReconnect(',
      'func nextReconnectAttemptCount(',
      'func beginReconnectAttempt(uuid:',
      'func registerInvalidParametersFailure(',
      'private func reconnectRetryTicket(',
      'private func isCurrentReconnectRetry(',
      'func deferInvalidParametersRetryIfNeeded(',
      'func connectPeripheral(',
      'func resumeDeferredReconnectFromFreshAdvertisement(',
      'private func activateClaimedStateRestoration(',
      'func adoptSystemAutoReconnect(',
      'func migrateReconnectTaskIdentityIfNeeded(',
    ]) {
      final start = source.indexOf(marker);
      expect(start, isNonNegative, reason: marker);
      var end = source.indexOf('{', start);
      var depth = 0;
      do {
        if (source[end] == '{') depth++;
        if (source[end] == '}') depth--;
        end++;
      } while (depth > 0);
      methods.add(source.substring(start, end).replaceFirst(
          'private func activateClaimedStateRestoration',
          'func activateClaimedStateRestoration'));
    }
    final admissionSource =
        File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
            .readAsStringSync();
    for (final marker in [
      'func retireUndispatchedReconnectAttempt(',
      'private func drivePeripheralConnection('
    ]) {
      final start = admissionSource.indexOf(marker);
      expect(start, isNonNegative, reason: marker);
      var end = admissionSource.indexOf('{', start);
      var depth = 0;
      do {
        if (admissionSource[end] == '{') depth++;
        if (admissionSource[end] == '}') depth--;
        end++;
      } while (depth > 0);
      // The harness invokes the physical driver directly; no production body is
      // modified, only its file-private visibility at this test entry boundary.
      methods.add(admissionSource
          .substring(start, end)
          .replaceFirst('private func ', 'func '));
    }

    final managerSource =
        File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final callbackStart =
        managerSource.indexOf('func acceptsCurrentPeripheralCallback(');
    var callbackEnd = managerSource.indexOf('{', callbackStart);
    var callbackDepth = 0;
    do {
      if (managerSource[callbackEnd] == '{') callbackDepth++;
      if (managerSource[callbackEnd] == '}') callbackDepth--;
      callbackEnd++;
    } while (callbackDepth > 0);
    methods.add(managerSource.substring(callbackStart, callbackEnd));
    final identitySource =
        File('ios/Classes/ble/BleReconnectStore.swift').readAsStringSync();
    final identityStart =
        identitySource.indexOf('enum BleReconnectIdentityPolicy {');
    var identityEnd = identitySource.indexOf('{', identityStart);
    var identityDepth = 0;
    do {
      if (identitySource[identityEnd] == '{') identityDepth++;
      if (identitySource[identityEnd] == '}') identityDepth--;
      identityEnd++;
    } while (identityDepth > 0);
    final identityPolicy = identitySource.substring(identityStart, identityEnd);
    final production = File('${directory.path}/production-retry.swift');
    await production.writeAsString(
        'import Foundation\n$identityPolicy\nextension BleManager {\n${methods.join('\n')}\n}');
    final executable = '${directory.path}/manager-test';
    final compile = await Process.run('swiftc', [
      'ios/Classes/ble/BleReconnectFailurePolicy.swift',
      production.path,
      'test/native/reconnect_retry_manager_fixture.swift',
      'test/native/reconnect_retry_manager_test.swift',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final run = await Process.run(executable, const []);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect(run.stdout, contains('one live job'));
  }, skip: !Platform.isMacOS);

  test('manager routes all reconnect entries through policy before dispatch',
      () {
    final source = File('ios/Classes/ble/BleAutoReconnectCoordinator.swift')
        .readAsStringSync();
    for (final marker in [
      'func activateArmedReconnectTask(',
      'func scheduleReconnect(',
      'func beginReconnectAttempt(uuid:',
      'func beginDirectReconnectAttempt(',
      'func connectPeripheral('
    ]) {
      final start = source.indexOf(marker);
      final next = source.indexOf('\n    func ', start + marker.length);
      final body = source.substring(start, next < 0 ? source.length : next);
      expect(body, contains('deferInvalidParametersRetryIfNeeded('),
          reason: marker);
    }
    final admission = File('ios/Classes/ble/BleConnectionAdmissionFlow.swift')
        .readAsStringSync();
    for (final entry in [
      ('func isCurrentConnectionPipeline(', 'let admission ='),
      (
        'func enqueuePhysicalConnectionThroughGate(',
        'session.hasObservedPhysicalContact = true'
      ),
      ('func startGrantedGattPipeline(', 'peripheral.delegate = self'),
    ]) {
      final start = admission.indexOf(entry.$1);
      final end = admission.indexOf('\n    func ', start + entry.$1.length);
      final body = admission.substring(start, end < 0 ? admission.length : end);
      final guardIndex = body.indexOf('peripheralValidity.isValid(');
      final effectIndex = body.indexOf(entry.$2);
      expect(guardIndex, isNonNegative, reason: entry.$1);
      expect(effectIndex, isNonNegative, reason: entry.$2);
      expect(guardIndex, lessThan(effectIndex), reason: entry.$1);
    }
    expect(
        source,
        contains(
            'claimResolution.mayUseClaimedObject ? claimedCandidate : nil'));
    expect(
        'claimResolution.applyingDebt(to: task.invalidParametersBackoff)'
            .allMatches(source)
            .length,
        2);
    final manager = File('ios/Classes/ble/BleManager.swift').readAsStringSync();
    final error =
        manager.substring(manager.indexOf('private func handleConnectError('));
    expect(error.indexOf('session.peripheral === peripheral'),
        lessThan(error.indexOf('registerInvalidParametersFailure(')));
    expect(error.indexOf('registerInvalidParametersFailure('),
        lessThan(error.indexOf('handleConnectState(')));
    final scan =
        File('ios/Classes/ble/BleScanPipeline.swift').readAsStringSync();
    expect(scan.indexOf('resumeDeferredReconnectFromFreshAdvertisement('),
        greaterThan(scan.indexOf('guard let deviceSn =')));
    expect(scan.indexOf('resumeDeferredReconnectFromFreshAdvertisement('),
        lessThan(scan.indexOf('guard !isCachedInCurrentScanWindow')));
  });
}
